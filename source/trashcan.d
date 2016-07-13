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

import isfreedesktop;

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
     * 
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
    
    @trusted string escapeValue(string value) pure {
        return value.replace("\\", `\\`).replace("\n", `\n`).replace("\r", `\r`).replace("\t", `\t`);
    }
    
    unittest 
    {
        assert("a\\next\nline\top".escapeValue() == `a\\next\nline\top`);
    }
    
    @trusted string ensureDirExists(string dir) {
        std.file.mkdirRecurse(dir);
        return dir;
    }
    
    import core.sys.posix.sys.types;
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;
    
    @trusted string topDir(string path)
    in {
        assert(path.isAbsolute);
    }
    out(result) {
        if (result.length) {
            assert(result.isAbsolute);
        }
    }
    body {
        auto current = path;
        stat_t currentStat;
        if (stat(current.toStringz, &currentStat) != 0) {
            return null;
        }
        stat_t parentStat;
        while(current != "/") {
            string parent = current.dirName;
            if (lstat(parent.toStringz, &parentStat) != 0) {
                return null;
            }
            if (currentStat.st_dev != parentStat.st_dev) {
                return current;
            }
            current = parent;
        }
        return current;
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
        checkDiskTrashMode(trashStat.st_mode);
        return trashDir;
    }
    
    string userTrashSubdir(string trashDir, uid_t uid) {
        return buildPath(trashDir, format("%s", uid));
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
            wchar[1024] msg;
            auto len = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM, null, r, 0, msg.ptr, msg.length - 1, null);
            
            if (len) {
                throw new Exception(msg[0..len].toUTF8().stripRight);
            } else {
                throw new Exception("File deletion error");
            }
        }
    } else version(OSX) {
        import std.exception;
        
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
            import xdgpaths;
            
            string dataPath = xdgDataHome(null, true);
            if (!dataPath.length) {
                throw new Exception("Could not access data folder");
            }
            dataPath = dataPath.absolutePath;
            
            string trashBasePath;
            
            if ((options & TrashOptions.useTopDirs) != 0) {
                string dataTopDir = topDir(dataPath);
                string fileTopDir = topDir(path);
                
                enforce(fileTopDir.length, "Could not get topdir of file being trashed");
                enforce(dataTopDir.length, "Could not get topdir of home data directory");
                
                if (dataTopDir != fileTopDir) {
                    try {
                        string diskTrash = checkDiskTrash(fileTopDir, (options & TrashOptions.checkStickyBit) != 0);
                        trashBasePath = ensureUserTrashSubdir(diskTrash);
                    } catch(Exception e) {
                        try {
                            if ((options & TrashOptions.fallbackToUserDir) != 0) {
                                trashBasePath = ensureUserTrashDir(fileTopDir);
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
            uint number = 1;
            
            while(trashInfoPath.exists || trashFilePath.exists) {
                string baseName = numberedBaseName(path, number);
                trashInfoPath = buildPath(trashInfoDir, baseName ~ ".trashinfo");
                trashFilePath = buildPath(trashFilePathsDir, baseName);
                number++;
            }
            
            import std.datetime;
            auto currentTime = Clock.currTime;
            currentTime.fracSecs = Duration.zero;
            string contents = format("[Trash Info]\nPath=%s\nDeletionDate=%s\n", path.escapeValue(), currentTime.toISOExtString());
            write(trashInfoPath, contents);
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
