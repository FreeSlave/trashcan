/+dub.sdl:
name "put"
dependency "trashcan" path="../"
+/
import std.path;
import std.stdio;
import trashcan;

void main(string[] args)
{
    if (args.length < 2) {
        writefln("No files given. Run %s FILE...", args[0]);
        return;
    }

    foreach(arg; args[1..$]) {
        try {
            moveToTrash(arg.absolutePath);
        } catch(Exception e) {
            stderr.writefln("Error while moving '%s' to trash: %s", arg, e.msg);
        }
    }
}
