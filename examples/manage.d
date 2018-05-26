/+dub.sdl:
name "manage"
dependency "trashcan" path="../"
+/
import std.path;
import std.stdio;
import std.array;
import std.exception;
import std.datetime.stopwatch;
import trashcan;

void printHelp()
{
    writeln("Possible commands: restore <index>; erase <index>; exit; help;");
}

void main()
{
    auto trashCan = new Trashcan();
    auto items = trashCan.byItem.array;
    foreach(i, item; items) {
        writefln("%s: %s (%s)", i, item.restorePath, item.isDir ? "directory" : "file");
    }
    string line;
    printHelp();
    write("$ ");
    while((line = readln()) !is null) {
        import std.string : stripRight;
        import std.conv : to;
        import std.algorithm.iteration : splitter;
        line = line.stripRight;
        auto splitted = line.splitter(' ');
        if (!splitted.empty) {
            try {
                string command = splitted.front;
                splitted.popFront();
                switch(command) {
                    case "erase":
                    case "delete":
                    {
                        foreach(arg; splitted) {
                            const index = arg.to!size_t;
                            enforce(index < items.length, "Wrong index " ~ arg);
                            trashCan.erase(items[index]);
                            writefln("Item %s %s deleted from trashcan", index, items[index].restorePath.baseName);
                        }
                    }
                    break;
                    case "restore":
                    case "undelete":
                    {
                        foreach(arg; splitted) {
                            const index = arg.to!size_t;
                            enforce(index < items.length, "Wrong index " ~ arg);
                            trashCan.restore(items[index]);
                            writefln("Item %s %s restored to its original location", index, items[index].restorePath.baseName);
                        }
                    }
                    break;
                    case "exit":
                    case "quit":
                        return;
                    case "help":
                    case "?":
                        printHelp();
                        break;
                    default:
                        stderr.writefln("Unknown command %s", command);
                        break;
                }
            } catch(Exception e) {
                stderr.writeln(e.msg);
            }
        }
        write("$ ");
    }
}
