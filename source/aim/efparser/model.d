/// This module contains the data structures representing an EF Model,
/// functions to parse a Model, and functions to validate a Model.
module aim.efparser.model;

import std.stdio, std.regex, std.experimental.logger, std.exception,
       std.format, std.algorithm, std.file, std.path, std.typecons;

/++ 
 + Contains information about a DbSet from EF.
 +
 + For example, the variable `DbSet<device_type> devices`
 + would correspond with `DbSet("device_type", "devices")`
 + ++/
struct DbSet
{
	/// The name of the type the set stores
	string typeName;

	/// The name of the variable the set is stored as, inside of the DbContext.
	string variableName;

    string toString()
    {
        return "DbSet<"~typeName~"> "~variableName~";";
    }
}

/// Contains the information about the DbContext class for the data model.
class DatabaseContext
{
    /// The name of the DbContext class.
	string  className;

    /// All of the tables that the context manages.
	DbSet[] tables;

    override string toString()
    {
        import std.algorithm;
        import std.array;
        import std.format;

        return format("[DbContext]\n"
                    ~ "Name: %s\n"
                    ~ "Tables:\n\t%s",
                    
                      this.className,
                      this.tables.map!(t => t.toString()).joiner("\n\n\t"));
    }

    /++
     + Gets the table (`DbSet`) for a certain type.
     +
     + Throws:
     +  `Exception` if no table could be found.
     +
     + Params:
     +  `type` = The name of the type to get the table for.
     +
     + Returns:
     +  The table found for `type`.
     + ++/
    @safe
    inout(DbSet) getTableForType(string type) inout
    {
        foreach(tab; this.tables)
        {
            if(tab.typeName == type)
                return tab;
        }

        throw new Exception(format("Could not find the table for type '%s'", type));
    }
}

/// Contains information about a specific field/variable.
class Field
{
    /// The name of the field's type. (e.g. "device", "int", etc.)
    string typeName;

    /// The name of the field.
    string variableName;

    /// The attributes applied to the field.
    string[] attributes;

    /// The field allows null values.
    bool allowsNull;

    override string toString() const
    {
        import std.format;
        import std.algorithm;

        return format("<AllowsNull:%s>\n%s\n%s %s;",
                      this.allowsNull,
                      this.attributes.map!(a => format("[%s]", a)).joiner("\n"),
                      this.typeName,
                      this.variableName);
    }
}

/// Contains information about an object in a table(DbSet).
class TableObject
{
    /// The name of the class.
	string className;

    /// The name of the variable that stores the object's primary key.
	string keyName;

    /// The name of the file the object is stored in.
	string fileName;

    /// All of the fields/variables that make up the object.
    Field[] fields;

    /// All the `TableObject`s that depend on this object.
    Dependant[] dependants;

    override string toString()
    {
        import std.algorithm;
        import std.format;

        return format("[Table Object]\n"
                    ~ "Name: %s\n"
                    ~ "KeyVar: %s\n"
                    ~ "File: '%s'\n"
                    ~ "Dependants: \n\t%s\n"
                    ~ "Fields:\n%s",
                    
                      this.className,
                      this.keyName,
                      this.fileName,
                      this.dependants.map!(d => d.dependant.className).joiner("\n\t"),
                      this.fields.map!(f => f.toString()).joiner("\n\n"));
    }

    /// Returns: The primary key field.
    inout(Field) getKey() inout
    {
        return this.getFieldByName(this.keyName, "Could not find the primary key field.");
    }

    /// Notes:
    ///  If a field with `name` doesn't exist then an exception is thrown, using `notFoundErrorMsg`
    ///  as additional information about why the field was needed (e.g. It's the key field, it's a foreign key, it's a generic value, etc.)
    ///
    /// Returns:
    ///   A `Field` with the given `name`.
    inout(Field) getFieldByName(string name, lazy string notFoundErrorMsg = "No additional info") inout
    {
        foreach(field; this.fields)
        {
            if(field.variableName == name)
                return field;
        }

        throw new Exception(format("Could not find field with name '%s' in object '%s'. Additional Info: %s", notFoundErrorMsg));
    }

    /// Returns: Whether this object has a field called `name`.
    bool hasField(string name)
    {
        try
        {
            this.getFieldByName(name);
            return true;
        }
        catch(Exception ex)
            return false;
    }
}

/// Contains information about a 'TableObject' that's dependent on another type.
struct Dependant
{
    /// The object that's dependent on another.
    TableObject dependant;

    /// The field that acts as the foreign key for the dependency.
    Field dependantFK;

    /// The field that acts as the foreign getter for the dependency.
    Field dependantGetter;
}

/// Contains information about the entire model.
class Model
{
    alias ValidateFunc = void function(const Model model);
    private static ValidateFunc[] _validationSteps;

    /// The namespace that all of the files in the model use.
	string          namespace; // Determined by the file holding the DbContext

    /// The main DbContext for the model.
	DatabaseContext context;

    /// The various objects that make up the model's data.
	TableObject[]   objects;

    override string toString()
    {
        return format("[Model]\n"
                    ~ "Namespace: %s\n"
                    ~ "Context:\n%s\n"
                    ~ "Objects:\n%s",
                    
                      this.namespace,
                      this.context,
                      this.objects.map!(o => o.toString()).joiner("\n\n"));
    }

    /// Returns: The `TableObject` with the given `type`.
    inout(TableObject) getObjectByType(string type) inout
    {
        foreach(obj; this.objects)
        {
            if(obj.className == type)
                return obj;
        }

        throw new Exception(format("Could not find the TableObject of type '%s'", type));
    }

    /// Returns: Whether `type` is a type of `TableObject`.
    bool isObjectType(string type) const
    {
        try
        {
            this.getObjectByType(type);
            return true;
        }
        catch(Exception ex)
            return false;
    }

    /++
    + Parses the directory created by EF, and gathers information about the model.
    +
    + Notes:
    +  The parsing has been designed for, and is only tested for, models generated
    +  by visual studio using the 'code-first from database' option.
    +
    + Params:
    +  dirPath = The path to the directory to parse.
    +
    + Returns:
    +  The parsed `Model`
    + ++/
    static Model parseDirectory(string dirPath)
    {
        enforce(dirPath.exists, "The path '%s' doesn't exist.".format(dirPath));
        enforce(dirPath.isDir, "The path '%s' doesn't point to a directory".format(dirPath));

        // Only has one match, which is the name of the DbContext class.
        auto dbModelNameRegex = regex(`public\spartial\sclass\s([a-zA-Z_]+)\s:\sDbContext`);

        // Only has one match, which is the name of the table object class.
        auto dbObjectNameRegex = regex(`public\spartial\sclass\s([a-zA-Z_]+)\s`);

        // Go over all of the files, and check what kind of data it contains, then pass it to the right function
        // to parse it.
        Model model = new Model();
        foreach(entry; dirEntries(dirPath, SpanMode.breadth))
        {
            if(entry.isDir || entry.extension != ".cs")
                continue;

            auto content = readText(entry);

            // Check if it's the DbContext file
            auto matches = matchFirst(content, dbModelNameRegex);
            if(matches.length > 1)
            {
                enforce(model.context is null, "The EF model contains multiple DbContext classes. There is no support for this.");

                // Reminder: [0] is always the fully matched string.
                //           The actual capture groups start at [1]
                parseDbContext(model, content, matches[1]);
                continue;
            }

            // Then, check if it's a 'public partial' class, which is probably one of the table objects.
            matches = matchFirst(content, dbObjectNameRegex);
            if(matches.length > 1)
            {
                parseObjectFile(model, content, matches[1], entry.name);
                continue;
            }
        }

        finaliseModel(model);
        return model;
    }

    /++
     + Registers a function that is used to validate the model after it has been parsed.
     +
     + This function must throw an exception on failure.
     +
     + Params:
     +  func = The func to use.
     + ++/
    static void registerValidationStep(ValidateFunc func)
    {
        assert(func !is null);

        Model._validationSteps ~= func;
    }
}

// Performs steps of the model parsing that can only be done after the entire model is read in.
private void finaliseModel(Model model)
{
    auto iCollectionRegex = regex(`ICollection<([a-zA-Z_0-9]+)>`);

    // Go over all the table objects, and find their dependants.
    foreach(object; model.objects)
    {
        // If a field is of the form "ICollection<SomeTableObject>" then that means
        // 'this' object is a dependency of 'SomeTableObject'.
        foreach(field; object.fields)
        {
            auto match = matchFirst(field.typeName, iCollectionRegex);
            if(match.length == 2)
            {
                Dependant info;
                info.dependant = model.getObjectByType(match[1]);
                info.dependantGetter = field;
                
                // Figure out the FK's variable name.
                if(info.dependant == object) // Special case: The object has an FK of another object with the same type (device for example)
                {
                    // Solution: Follow the convention of naming the FK 'parent_[type name]_id'
                    // Future Solution: Read in a file that can provide an FK name for special cases like this
                    auto fkName = "parent_" ~ info.dependant.className ~ "_id";
                    auto fkQuery = info.dependant.getFieldByName(fkName, "Special FK case failed");
                    info.dependantFK = fkQuery;
                }
                else // Non-special cases
                {
                    // Naming convention: Simply slap "_id" after the type name and it makes a foreign key
                    // If this is violated, or EF generates special cases, then this logic fails.
                    auto fkName = object.className ~ "_id";
                    auto fkQuery = info.dependant.getFieldByName(fkName, "Could not find the foreign key, are you following the naming convention?");
                    info.dependantFK = fkQuery;
                }

                object.dependants ~= info;
            }
        }
    }
}

// Parses a file describing the class that inherits from DbContext
private void parseDbContext(Model model, string content, string className)
{
    // Contains two matches, [1] is the class name of the DbSet, [2] is the variable name of the DbSet
	auto dbModelDbSetRegex = regex(`public\svirtual\sDbSet<([a-zA-Z_]+)>\s([a-zA-Z_]+)\s`);

    // Only has one match, which is the namespace
	auto dbModelNamespaceRegex = regex(`namespace\s([a-zA-Z\._]+)\s`);

    model.context = new DatabaseContext();
    model.context.className = className;

    // Figure out which namespace this class is in.
    auto matches = matchFirst(content, dbModelNamespaceRegex);
    enforce(matches.length == 2, "Could not determine the namespace for the model.");
    model.namespace = matches[1];   

    // Look for all of the DbSets in the context, which represent tables.
    auto tableMatches = matchAll(content, dbModelDbSetRegex);
    foreach(match; tableMatches)
    {
        assert(match.length == 3);

        DbSet set;
        set.typeName = match[1];
        set.variableName = match[2];

        model.context.tables ~= set;
    }
}

// Parses a file that represents a record of a table from the database (I call them TableObjects in the generator's codebase)
private void parseObjectFile(Model model, string content, string className, string filePath)
{
    // This function is called multiple times, so ctRegex is being used instead of the normal regex.

    // Only has one match, which is the name of the object's key variable.
	auto dbObjectKeyNameRegex = ctRegex!(`\[Key\]\s*\[?[^\]]+\]?\s*public\sint\s([a-zA-Z_0-1]+)\s\{\sget;\sset;\s\}`);

    // Used to check for a ctor
    auto dbObjectCtorRegex = regex(format(`public (%s)\(\)`, className));

    // Used to check for a '}'
    auto dbObjectEndCurlyRegex = ctRegex!`\s*(\})\s*`;

    // [1] = Whatever's inside the attribute brackets
    auto dbObjectAttributeRegex = ctRegex!`\[([^\]]+)\]`;

    // [1] = Type name. [2] = Variable name.
    auto dbObjectFieldRegex = ctRegex!`public\s(?:virtual\s)?([^\s]+)\s([^\s]+)\s\{\sget;\sset;\s\}`;

    TableObject object = new TableObject();
    object.className = className;
    object.fileName  = filePath.baseName;

    // Search the file's content line-by-line
    // First thing is to skip over the constructor, then the only things that are left are the
    // fields.
    // Then parse in all the fields.
    bool hasCtor = (matchFirst(content, dbObjectCtorRegex).length > 1);
    bool foundCtor = false;
    bool skippedCtor = false;
    string[] attributes;
    foreach(line; content.splitter('\n'))
    {
        // Look for the ctor
        if(!foundCtor && hasCtor)
        {
            auto matches = matchFirst(line, dbObjectCtorRegex);
            if(matches.length > 1)
                foundCtor = true;

            continue;
        }
        else if(!skippedCtor && hasCtor) // Look for the first '}' that ends the ctor.
        {
            auto matches = matchFirst(line, dbObjectEndCurlyRegex);
            if(matches.length > 1)
                skippedCtor = true;

            continue;
        }

        // Push all of the attributes onto a list
        // When a field is found, associate the attributes with it
        // Clear the attributes list
        // Repeat until the end of the contents.

        auto atribMatches = matchFirst(line, dbObjectAttributeRegex);
        if(atribMatches.length > 1) // Attribute found
        {
            attributes ~= atribMatches[1];
            continue;
        }

        auto fieldMatches = matchFirst(line, dbObjectFieldRegex);
        if(fieldMatches.length > 1) // Field found
        {
            assert(fieldMatches.length == 3);

            // Setup the field.
            Field field = new Field();
            field.typeName = fieldMatches[1];
            field.variableName = fieldMatches[2];
            field.attributes = attributes;

            object.fields ~= field;

            // Special case: I can't be bothered to change the code that already uses 'keyName'
            // So we'll just handle the Key attribute here.
            auto query = field.attributes.filter!(a => a == "Key");
            if(!query.empty)
                object.keyName = field.variableName;

            // Then reset the attribute list.
            attributes = null;

            // Figure out if the field allows nulls.
            if(field.typeName[$-1] == '?')
            {
                field.allowsNull = true;
                field.typeName = field.typeName[0..$-1];
            }

            if(field.typeName == "string" && !field.attributes.any!(a => a == "Required"))
                field.allowsNull = true;
            continue;
        }
    }

    assert(object.fields.length > 0, object.className);
    model.objects ~= object;
}

// Performs certain validation steps to ensure that the model is formed correctly.
void validateModel(const Model model)
{
    foreach(step; Model._validationSteps)
        step(model);
}

static this()
{
    // #1, make sure that for each table object, that there's a corresponding DbSet inside the DbContext.
    Model.registerValidationStep((model)
    {
        import std.algorithm : canFind;
        foreach(object; model.objects)
        {
            bool found = model.context.tables.canFind!(t => t.typeName == object.className);
            enforce(found, format("The DbContext '%s' has no DbSet for the table object '%s",
                                  model.context.className, object.className));
        }
    });

    // #2, make sure all objects have a primary key field.
    Model.registerValidationStep((model)
    {
        foreach(object; model.objects)
        object.getKey(); // This will throw if it can't find the key
    });
}