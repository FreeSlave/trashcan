# Trash can

Move files and directories to trash can (Recycle bin) in D programming language. 
Currently it contains only one function **moveToTrash** which places passed file or directory to trash can.

## Platform support

On Windows [SHFileOperation](https://msdn.microsoft.com/en-us/library/windows/desktop/bb762164(v=vs.85).aspx) is used.

On Freedesktop environments (e.g. GNU/Linux) the library will follow [Trash Can Specification](https://www.freedesktop.org/wiki/Specifications/trash-spec/).

Other platforms are not supported yet.

## Future improvements:

* Interface for observing the trash can contents (something like VFS).
* Ability to restore deleted files.
* Better compatibility with specification on freedesktop.
