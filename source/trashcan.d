/**
 * Moving files and directories to trash can.
 * Copyright:
 *  Roman Chistokhodov, 2016
 * License:
 *  $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */

module trashcan;

import std.path;
import std.string;
import std.file;
import std.exception;
import std.range : InputRange, inputRangeObject;

import isfreedesktop;

static if (isFreedesktop) {
    import std.uri : encode, decode;
    import volumeinfo;
    import inilike.file;
    import xdgpaths : xdgDataHome;
}

/**
 * Flags to rule the trashing behavior.
 *
 * $(BLUE Valid only for freedesktop environments).
 *
 * See_Also: $(LINK2 https://specifications.freedesktop.org/trash-spec/trashspec-1.0.html, Trash specification).
 */
enum TrashOptions : int
{
    /**
     * No options. Just move file to user home trash directory
     * not paying attention to partition where file resides.
     */
    none = 0,
    /**
     * If file that needs to be deleted resides on non-home partition
     * and top trash directory ($topdir/.Trash/$uid) failed some check,
     * fallback to user top trash directory ($topdir/.Trash-$uid).
     *
     * Makes sense only in conjunction with $(D useTopDirs).
     */
    fallbackToUserDir = 1,
    /**
     * If file that needs to be deleted resides on non-home partition
     * and checks for top trash directories failed,
     * fallback to home trash directory.
     *
     * Makes sense only in conjunction with $(D useTopDirs).
     */
    fallbackToHomeDir = 2,

    /**
     * Whether to use top trash directories at all.
     *
     * If no $(D fallbackToUserDir) nor $(D fallbackToHomeDir) flags are set,
     * and file that needs to be deleted resides on non-home partition,
     * and top trash directory ($topdir/.Trash/$uid) failed some check,
     * exception will be thrown. This can be used to report errors to administrator or user.
     */
    useTopDirs = 4,

    /**
     * Whether to check presence of 'sticky bit' on $topdir/.Trash directory.
     *
     * Makes sense only in conjunction with $(D useTopDirs).
     */
    checkStickyBit = 8,

    /**
     * All flags set.
     */
    all = (TrashOptions.fallbackToUserDir | TrashOptions.fallbackToHomeDir | TrashOptions.checkStickyBit | TrashOptions.useTopDirs)
}

static if (isFreedesktop)
{
private:
    import std.format : format;

    @trusted string numberedBaseName(string path, uint number) {
        return format("%s %s%s", path.baseName.stripExtension, number, path.extension);
    }

    unittest
    {
        assert(numberedBaseName("/root/file.ext", 1) == "file 1.ext");
        assert(numberedBaseName("/root/file", 2) == "file 2");
    }

    @trusted string ensureDirExists(string dir) {
        std.file.mkdirRecurse(dir);
        return dir;
    }

    import core.sys.posix.sys.types;
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;

    @trusted string topDir(string path)
    in {
        assert(path.isAbsolute);
    }
    body {
        return volumePath(path);
    }

    void checkDiskTrashMode(mode_t mode, const bool checkStickyBit = true)
    {
        enforce(!S_ISLNK(mode), "Top trash directory is a symbolic link");
        enforce(S_ISDIR(mode), "Top trash path is not a directory");
        if (checkStickyBit) {
            enforce((mode & S_ISVTX) != 0, "Top trash directory does not have sticky bit");
        }
    }

    unittest
    {
        assertThrown(checkDiskTrashMode(S_IFLNK|S_ISVTX));
        assertThrown(checkDiskTrashMode(S_IFDIR));
        assertNotThrown(checkDiskTrashMode(S_IFDIR|S_ISVTX));
        assertNotThrown(checkDiskTrashMode(S_IFDIR, false));
    }

    @trusted string checkDiskTrash(string topdir, const bool checkStickyBit = true)
    in {
        assert(topdir.length);
    }
    body {
        string trashDir = buildPath(topdir, ".Trash");
        stat_t trashStat;
        enforce(lstat(trashDir.toStringz, &trashStat) == 0, "Top trash directory does not exist");
        checkDiskTrashMode(trashStat.st_mode, checkStickyBit);
        return trashDir;
    }

    string userTrashSubdir(string trashDir, uid_t uid) {
        import std.conv : to;
        return buildPath(trashDir, uid.to!string);
    }

    unittest
    {
        assert(userTrashSubdir("/.Trash", 600) == buildPath("/.Trash", "600"));
    }

    @trusted string ensureUserTrashSubdir(string trashDir)
    {
        return userTrashSubdir(trashDir, getuid()).ensureDirExists();
    }

    string userTrashDir(string topdir, uid_t uid) {
        return buildPath(topdir, format(".Trash-%s", uid));
    }

    unittest
    {
        assert(userTrashDir("/topdir", 700) == buildPath("/topdir", ".Trash-700"));
    }

    @trusted string ensureUserTrashDir(string topdir)
    {
        return userTrashDir(topdir, getuid()).ensureDirExists();
    }
}

version(OSX)
{
private:
    import core.sys.posix.dlfcn;

    struct FSRef {
        char[80] hidden;
    };

    alias ubyte Boolean;
    alias int OSStatus;
    alias uint OptionBits;

    extern(C) @nogc @system OSStatus _dummy_FSPathMakeRefWithOptions(const(char)* path, OptionBits, FSRef*, Boolean*) nothrow {return 0;}
    extern(C) @nogc @system OSStatus _dummy_FSMoveObjectToTrashSync(const(FSRef)*, FSRef*, OptionBits) nothrow {return 0;}
}

/**
 * Move file or directory to trash can.
 * Params:
 *  path = Path of item to remove. Must be absolute.
 *  options = Control behavior of trashing on freedesktop environments.
 * Throws:
 *  Exception when given path is not absolute or does not exist or some error occured during operation.
 */
@trusted void moveToTrash(string path, TrashOptions options = TrashOptions.all)
{
    if (!path.isAbsolute) {
        throw new Exception("Path must be absolute");
    }
    if (!path.exists) {
        throw new Exception("Path does not exist");
    }

    version(Windows) {
        import core.sys.windows.shellapi;
        import core.sys.windows.winbase;
        import core.stdc.wchar_;
        import std.windows.syserror;
        import std.utf;

        SHFILEOPSTRUCTW fileOp;
        fileOp.wFunc = FO_DELETE;
        fileOp.fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR | FOF_ALLOWUNDO;
        auto wFileName = (path ~ "\0\0").toUTF16();
        fileOp.pFrom = wFileName.ptr;
        int r = SHFileOperation(&fileOp);
        if (r != 0) {
            import std.format;
            throw new Exception(format("SHFileOperation failed with error code %d", r));
        }
    } else version(OSX) {
        void* handle = dlopen("CoreServices.framework/Versions/A/CoreServices", RTLD_NOW | RTLD_LOCAL);
        if (handle !is null) {
            scope(exit) dlclose(handle);

            auto ptrFSPathMakeRefWithOptions = cast(typeof(&_dummy_FSPathMakeRefWithOptions))dlsym(handle, "FSPathMakeRefWithOptions");
            if (ptrFSPathMakeRefWithOptions is null) {
                throw new Exception(fromStringz(dlerror()).idup);
            }

            auto ptrFSMoveObjectToTrashSync = cast(typeof(&_dummy_FSMoveObjectToTrashSync))dlsym(handle, "FSMoveObjectToTrashSync");
            if (ptrFSMoveObjectToTrashSync is null) {
                throw new Exception(fromStringz(dlerror()).idup);
            }

            FSRef source;
            enforce(ptrFSPathMakeRefWithOptions(toStringz(path), 1, &source, null) == 0, "Could not make FSRef from path");
            FSRef target;
            enforce(ptrFSMoveObjectToTrashSync(&source, &target, 0) == 0, "Could not move path to trash");
        } else {
            throw new Exception(fromStringz(dlerror()).idup);
        }
    } else {
        static if (isFreedesktop) {
            string dataPath = xdgDataHome(null, true);
            if (!dataPath.length) {
                throw new Exception("Could not access data folder");
            }
            dataPath = dataPath.absolutePath;

            string trashBasePath;
            bool usingTopdir = false;
            string fileTopDir;

            if ((options & TrashOptions.useTopDirs) != 0) {
                string dataTopDir = topDir(dataPath);
                fileTopDir = topDir(path);

                enforce(fileTopDir.length, "Could not get topdir of file being trashed");
                enforce(dataTopDir.length, "Could not get topdir of home data directory");

                if (dataTopDir != fileTopDir) {
                    try {
                        string diskTrash = checkDiskTrash(fileTopDir, (options & TrashOptions.checkStickyBit) != 0);
                        trashBasePath = ensureUserTrashSubdir(diskTrash);
                        usingTopdir = true;
                    } catch(Exception e) {
                        try {
                            if ((options & TrashOptions.fallbackToUserDir) != 0) {
                                trashBasePath = ensureUserTrashDir(fileTopDir);
                                usingTopdir = true;
                            } else {
                                throw e;
                            }
                        } catch(Exception e) {
                            if (!(options & TrashOptions.fallbackToHomeDir)) {
                                throw e;
                            }
                        }
                    }
                }
            }

            if (trashBasePath is null) {
                trashBasePath = ensureDirExists(buildPath(dataPath, "Trash"));
            }
            enforce(trashBasePath.length, "Could not access base trash folder");

            string trashInfoDir = ensureDirExists(buildPath(trashBasePath, "info"));
            string trashFilePathsDir = ensureDirExists(buildPath(trashBasePath, "files"));

            string trashInfoPath = buildPath(trashInfoDir, path.baseName ~ ".trashinfo");
            string trashFilePath = buildPath(trashFilePathsDir, path.baseName);

            import std.datetime;
            import std.conv : octal;
            import core.stdc.errno;

            auto currentTime = Clock.currTime;
            currentTime.fracSecs = Duration.zero;
            string timeString = currentTime.toISOExtString();
            string contents = format("[Trash Info]\nPath=%s\nDeletionDate=%s\n", (usingTopdir ? path.relativePath(fileTopDir) : path).encode(), timeString);

            const mode = O_CREAT | O_WRONLY | O_EXCL;
            int fd;
            uint number = 1;
            while(trashFilePath.exists || ((fd = .open(toStringz(trashInfoPath), mode, octal!666)) == -1 && errno == EEXIST)) {
                string baseName = numberedBaseName(path, number);
                trashFilePath = buildPath(trashFilePathsDir, baseName);
                trashInfoPath = buildPath(trashInfoDir, baseName ~ ".trashinfo");
                number++;
            }
            errnoEnforce(fd != -1);
            scope(exit) .close(fd);
            errnoEnforce(write(fd, contents.ptr, contents.length) == contents.length);

            path.rename(trashFilePath);
        } else {
            static assert("Unsupported platform");
        }
    }
}

unittest
{
    assertThrown(moveToTrash("notabsolute"));
}

version(Windows)
{
    import std.utf : toUTF8;
    import std.typecons : RefCounted, refCounted, RefCountedAutoInitialize;
    import std.windows.syserror : WindowsException;

    import core.sys.windows.windows;
    import core.sys.windows.shlobj;

    pragma(lib, "Ole32");
}

version(Windows) private struct ItemIdList
{
    @disable this(this);
    this(LPITEMIDLIST pidl) {
        this.pidl = pidl;
    }
    alias pidl this;
    LPITEMIDLIST pidl;
    ~this() {
        if (pidl) {
            CoTaskMemFree(pidl);
            pidl = null;
        }
    }
}

/// Item (file or folder) stored in the trashcan.
struct TrashcanItem
{
    version(Windows) private @trusted this(string restorePath, bool isDir, LPITEMIDLIST pidl) {
        _restorePath = restorePath;
        _isDir = isDir;
        this.pidl = refCounted(ItemIdList(pidl));
    }
    static if (isFreedesktop) {
        private @trusted this(string restorePath, bool isDir, string trashInfoPath, string trashedPath) {
            assert(trashInfoPath.length != 0);
            assert(trashedPath.length != 0);
            _restorePath = restorePath;
            _isDir = isDir;
            _trashInfoPath = trashInfoPath;
            _trashedPath = trashedPath;
        }
    }
    /// Original location of item (before it was moved to trashcan).
    @safe @property @nogc nothrow const pure string restorePath() {
        return _restorePath;
    }
    /// Whether the item is directory.
    @safe @property @nogc nothrow const pure  bool isDir() {
        return _isDir;
    }
    version(D_Ddoc) {
        alias void* LPITEMIDLIST;
        /**
         * Windows-specific function to get LPITEMIDLIST associated with item.
         * Note:
         *  The returned object must not outlive this TrashcanItem (or its copies). If you want to keep this object around use $(LINK2 https://msdn.microsoft.com/en-us/library/windows/desktop/bb776433(v=vs.85).aspx, ILClone). Don't forget to call ILFree or CoTaskMemFree, when it's no longer needed.
         */
        @system @property @nogc nothrow LPITEMIDLIST itemIdList() {return null;}
        /**
         * Freedesktop-specific function to get .trashinfo file path.
         */
        @property @nogc nothrow string trashInfoPath() const {return string.init;}
        /**
         * Freedesktop-specific function to get the path where the trashed file or directory is located.
         */
        @property @nogc nothrow string trashedPath() const {return string.init;}
    } else version(Windows) {
        @system @property @nogc nothrow LPITEMIDLIST itemIdList() {
            assert(pidl.refCountedStore.isInitialized);
            return pidl;
        }
    } else static if (isFreedesktop) {
        @safe @property @nogc nothrow string trashInfoPath() const {
            return _trashInfoPath;
        }
        @safe @property @nogc nothrow string trashedPath() const {
            return _trashedPath;
        }
    }
private:
    string _restorePath;
    bool _isDir;
    version(Windows) RefCounted!(ItemIdList, RefCountedAutoInitialize.no) pidl;
    static if (isFreedesktop) {
        string _trashInfoPath;
        string _trashedPath;
    }
}

version(Windows) private
{
    static @trusted string StrRetToString(ref STRRET strRet)
    {
        switch (strRet.uType)
        {
        case STRRET_CSTR:
            return fromStringz(strRet.cStr.ptr).idup;
        case STRRET_OFFSET:
            return string.init;
        case STRRET_WSTR:
            char[MAX_PATH] szTemp;
            auto len = WideCharToMultiByte (CP_ACP, 0, strRet.pOleStr, -1, szTemp.ptr, szTemp.sizeof, null, null);
            scope(exit) CoTaskMemFree(strRet.pOleStr);
            if (len)
                return szTemp[0..len-1].idup;
            else
                return string.init;
        default:
            return string.init;
        }
    }

    @safe static void henforce(HRESULT hres, lazy string msg = null, string file = __FILE__, size_t line = __LINE__)
    {
        if (hres != S_OK)
            throw new WindowsException(hres, msg, file, line);
    }

    @trusted static getDisplayNameOf(IShellFolder folder, LPITEMIDLIST pidl)
    {
        assert(folder);
        assert(pidl);
        STRRET strRet;
        henforce(folder.GetDisplayNameOf (pidl, SHGNO.SHGDN_NORMAL, &strRet), "Failed to get a display name");
        return StrRetToString(strRet);
    }

    @trusted static void RunVerb(string verb)(IShellFolder folder, LPITEMIDLIST pidl)
    {
        enforce(pidl !is null, "Empty trashcan item, can't run an operation");
        IContextMenu contextMenu;
        henforce(folder.GetUIObjectOf(null, 1, cast(LPCITEMIDLIST*)(&pidl), &IID_IContextMenu, null, cast(LPVOID *)&contextMenu), "Failed to get context menu ui object");
        assert(pidl);
        assert(contextMenu);
        scope(exit) contextMenu.Release();
        CMINVOKECOMMANDINFO ci;
        ci.fMask = CMIC_MASK_FLAG_NO_UI;
        ci.cbSize = CMINVOKECOMMANDINFO.sizeof;
        ci.lpVerb  = verb;
        henforce(contextMenu.InvokeCommand(&ci), "Failed to " ~ verb ~ " item");
    }
}

/// Interface to trashcan.
interface ITrashcan
{
    /// List items stored in trashcan.
    @trusted InputRange!TrashcanItem byItem();
    /// Restore item to its original location.
    @safe void restore(TrashcanItem item);
    /// Erase item from trashcan.
    @safe void erase(TrashcanItem item);
    /// The name of trashcan (possibly localized).
    @safe string displayName();
}

version(D_Ddoc)
{
    /**
     * Implementation of $(D ITrashcan). This class may have additional platform-dependent functions and different constructors.
     * This class is currently available only for $(BLUE Windows) and $(BLUE Freedesktop) (GNU/Linux, FreeBSD, etc.) platforms.
     */
    final class Trashcan
    {
        ///
        @trusted this() {}
        /// Lazily list items stored in trashcan.
        @trusted InputRange!TrashcanItem byItem() {return null;}
        /**
         * Restore item to its original location.
         * Throws:
         *  $(B WindowsException) on Windows when could not invoke the operation.
         *  $(B FileException) on Posix when could not move the item to its original location or could not recreate original location directory.
         */
        @safe void restore(TrashcanItem item) {}
        /**
         * Erase item from trashcan.
         * On Windows it brings up the GUI dialog. If you know how to implement silent deleting, make a pull request!
         * Throws:
         *  $(B WindowsException) on Windows when could not invoke the operation.
         *  $(B FileException) on Posix when could not delete the item.
         */
        @safe void erase(TrashcanItem item) {}
        /// The name of trashcan (possibly localized).
        @safe string displayName() {return string.init;}
    }
}
else version(Windows) final class Trashcan : ITrashcan
{
    @trusted this() {
        OleInitialize(null);
        IShellFolder desktop;
        LPITEMIDLIST pidlRecycleBin;

        henforce(SHGetDesktopFolder(&desktop), "Failed to get desktop shell folder");
        assert(desktop);
        scope(exit) desktop.Release();
        henforce(SHGetSpecialFolderLocation(null, CSIDL_BITBUCKET, &pidlRecycleBin), "Failed to get recycle bin location");
        assert(pidlRecycleBin);
        scope(exit) ILFree(pidlRecycleBin);

        henforce(desktop.BindToObject(pidlRecycleBin, null, &IID_IShellFolder, cast(LPVOID *)&recycleBin), "Failed to get recycle bin shell folder");
        _displayName = getDisplayNameOf(desktop, pidlRecycleBin);
        assert(recycleBin);
    }

    @trusted ~this() {
        assert(recycleBin);
        recycleBin.Release();
        OleUninitialize();
    }

    private static struct ByItem
    {
        this(IShellFolder folder) {
            this.folder = folder;
            folder.AddRef();
            with(SHCONTF) henforce(folder.EnumObjects(null, SHCONTF_FOLDERS | SHCONTF_NONFOLDERS | SHCONTF_INCLUDEHIDDEN, &enumFiles), "Failed to enumerate objects in recycle bin");
            popFront();
        }
        this(this) {
            if (enumFiles)
                enumFiles.AddRef();
            if (folder)
                folder.AddRef();
        }
        ~this() {
            if (enumFiles)
                enumFiles.Release();
            if (folder)
                folder.Release();
        }
        TrashcanItem front() {
            return current;
        }
        TrashcanItem moveFront() {
            import std.algorithm.mutation : move;
            return move(current);
        }
        void popFront() {
            LPITEMIDLIST pidl;
            if (enumFiles.Next(1, &pidl, null) == S_FALSE) {
                atTheEnd = true;
            } else {
                assert(pidl);
                ULONG attributes = SFGAOF.SFGAO_FOLDER;
                folder.GetAttributesOf(1,cast(LPCITEMIDLIST *)&pidl,&attributes);
                current = TrashcanItem(getDisplayNameOf(folder, pidl), !!(attributes & SFGAOF.SFGAO_FOLDER), pidl);
            }
        }
        bool empty() {
            return atTheEnd;
        }
    private:
        IShellFolder folder;
        IEnumIDList enumFiles;
        TrashcanItem current;
        bool atTheEnd;
    }

    @trusted InputRange!TrashcanItem byItem() {
        return inputRangeObject(ByItem(recycleBin));
    }

    @safe void restore(TrashcanItem item) {
        RunVerb!"undelete"(recycleBin, item.pidl);
    }
    @safe void erase(TrashcanItem item) {
        RunVerb!"delete"(recycleBin, item.pidl);
    }
    @safe string displayName() {
        return _displayName;
    }
private:
    string _displayName;
    IShellFolder recycleBin;
} else static if (isFreedesktop)
{
    final class Trashcan : ITrashcan
    {
        private @safe static bool isDirNothrow(string path) nothrow {
            bool isDirectory;
            if (collectException(path.isDir, isDirectory) is null)
                return isDirectory;
            return false;
        }

        @safe this() {
        }

        import std.typecons : Tuple;

        @trusted InputRange!TrashcanItem byItem() {
            import std.algorithm.iteration : cache, map, joiner, filter;
            alias Tuple!(string, "base", string, "info", string, "files", string, "root") TrashLocation;
            return inputRangeObject(standardTrashBasePaths().map!(trashDir => TrashLocation(trashDir.base, buildPath(trashDir.base, "info"), buildPath(trashDir.base, "files"), trashDir.root)).filter!(t => isDirNothrow(t.info) && isDirNothrow(t.files)).map!(delegate(TrashLocation trash) {
                InputRange!TrashcanItem toReturn;
                try {
                    toReturn = inputRangeObject(dirEntries(trash.info, SpanMode.shallow, false).filter!(entry => entry.extension == ".trashinfo").map!(delegate(DirEntry entry) {
                        string trashedFile = buildPath(trash.files, entry.baseName.stripExtension);
                        try {
                            if (exists(trashedFile)) {
                                import inilike.read;

                                string path;

                                auto onLeadingComment = delegate void(string line) {};
                                auto onGroup = delegate ActionOnGroup(string groupName) {
                                    if (groupName == "Trash Info")
                                        return ActionOnGroup.stopAfter;
                                    return ActionOnGroup.skip;
                                };
                                auto onKeyValue = delegate void(string key, string value, string groupName) {
                                    if (groupName == "Trash Info" && key == "Path")
                                        path = value;
                                };
                                auto onCommentInGroup = delegate void(string line, string groupName) {};
                                readIniLike(iniLikeFileReader(entry.name), onLeadingComment, onGroup, onKeyValue, onCommentInGroup);

                                if (path.length) {
                                    path = path.decode();
                                    string restorePath;
                                    if (path.isAbsolute)
                                        restorePath = path;
                                    else
                                        restorePath = buildPath(trash.root, path);
                                    return TrashcanItem(restorePath, trashedFile.isDir, entry.name, trashedFile);
                                }
                            }
                        } catch(Exception e) {}
                        return TrashcanItem.init;
                    }).cache.filter!(item => item.restorePath.length));
                } catch(Exception e) {
                    toReturn = inputRangeObject(TrashcanItem[].init);
                }
                return toReturn;
            }).cache.joiner);
        }

        @safe void restore(TrashcanItem item) {
            mkdirRecurse(item.restorePath.dirName);
            rename(item.trashedPath, item.restorePath);
            collectException(remove(item.trashInfoPath));
        }
        @safe void erase(TrashcanItem item) {
            remove(item.trashedPath);
            collectException(remove(item.trashInfoPath));
        }
        @safe string displayName() {
            return "Trash";
        }
    private:
        alias Tuple!(string, "base", string, "root") TrashRoot;
        @trusted static TrashRoot[] standardTrashBasePaths() {
            TrashRoot[] trashBasePaths;
            import core.sys.posix.unistd;

            string homeTrashPath = xdgDataHome("Trash");
            string homeTrashTopDir;
            if (homeTrashPath.length && homeTrashPath.isAbsolute && isDirNothrow(homeTrashPath)) {
                homeTrashTopDir = homeTrashPath.topDir;
                trashBasePaths ~= TrashRoot(homeTrashPath, homeTrashTopDir);
            }

            auto userId = getuid();
            auto volumes = mountedVolumes();
            foreach(volume; volumes) {
                if (!volume.isValid)
                    continue;
                if (homeTrashTopDir == volume.path)
                    continue;
                string diskTrash;
                string userTrash;
                if (collectException(checkDiskTrash(volume.path), diskTrash) is null) {
                    userTrash = userTrashSubdir(diskTrash, userId);
                    if (isDirNothrow(userTrash))
                        trashBasePaths ~= TrashRoot(userTrash, volume.path);
                }
                userTrash = userTrashDir(volume.path, userId);
                if (isDirNothrow(userTrash))
                    trashBasePaths ~= TrashRoot(userTrash, volume.path);
            }
            return trashBasePaths;
        }
    }
}
