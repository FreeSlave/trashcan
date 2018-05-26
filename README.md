# Trash can

[![Build Status](https://travis-ci.org/FreeSlave/trashcan.svg?branch=master)](https://travis-ci.org/FreeSlave/trashcan) [![Windows Build Status](https://ci.appveyor.com/api/projects/status/github/FreeSlave/trashcan?branch=master&svg=true)](https://ci.appveyor.com/project/FreeSlave/trashcan)

Trash can operations implemented in D programming language.
**moveToTrash** function places a passed file or directory to trash can. **Trashcan** class allows to list trashcan contents, restore or delete items.

## Platform support and implementation details

On Freedesktop environments (e.g. GNU/Linux) the library follows [Trash Can Specification](https://www.freedesktop.org/wiki/Specifications/trash-spec/).

On Windows [SHFileOperation](https://msdn.microsoft.com/en-us/library/windows/desktop/bb762164(v=vs.85).aspx) is used to move files to trash, and [IShellFolder](https://msdn.microsoft.com/en-us/library/windows/desktop/bb775075(v=vs.85).aspx) is used as an interface to recycle bin to list, delete and undelete items.

On OSX FSMoveObjectToTrashSync is used to move files to trash. Listing, deleting and undeleting items in the trash can are not currently supported on macOS.

Other platforms are not supported.

## Examples

### [Put to trash can](examples/put.d)

Run to put file or directory to trash can:

    dub examples/put.d path/to/file

### [Manage items in trashcan](examples/manage.d)

Interactively delete items from trashcan or restore them to their original location.

    dub examples/manage.d
