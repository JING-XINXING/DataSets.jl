#
# Storage Driver implementation for trees which are rooted in the file system
# (in git terminology, there exists a "working copy")
#
abstract type AbstractFileSystemRoot end

# These underscore functions _abspath and _joinpath generate/joins OS-specific
# _local filesystem paths_ out of logical paths. They should be defined only
# for trees which are rooted in the actual filesystem.
function _abspath(root::AbstractFileSystemRoot, path::RelPath)
    rootpath = _abspath(root)
    return isempty(path.components) ? rootpath : joinpath(rootpath, _joinpath(path))
end

_joinpath(path::RelPath) = isempty(path.components) ? "" : joinpath(path.components...)
_abspath(path::AbsPath) = _abspath(path.root, path.path)
_abspath(tree::BlobTree) = _abspath(tree.root, tree.path)
_abspath(file::Blob) = _abspath(file.root, file.path)

# TODO: would it be better to express the following dispatch in terms of
# AbsPath{<:AbstractFileSystemRoot} rather than usin double dispatch?
Base.isdir(root::AbstractFileSystemRoot, path::RelPath) = isdir(_abspath(root, path))
Base.isfile(root::AbstractFileSystemRoot, path::RelPath) = isfile(_abspath(root, path))

# TODO: Is it possible to get a generic version of this without type piracy?
function Base.open(::Type{T}, file::Blob{<:AbstractFileSystemRoot}; kws...) where {T}
    open(identity, T, file)
end

function Base.open(f::Function, ::Type{IO}, file::Blob{<:AbstractFileSystemRoot};
                   write=false, read=!write, kws...)
    if !iswriteable(file.root) && write
        error("Error writing file at read-only path $path")
    end
    check_scoped_open(f, IO)
    open(f, _abspath(file.root, file.path); read=read, write=write, kws...)
end

function Base.mkdir(root::AbstractFileSystemRoot, path::RelPath; kws...)
    if !iswriteable(root)
        error("Cannot make directory in read-only tree root at $(_abspath(p.root))")
    end
    mkdir(_abspath(root, path), args...)
    return BlobTree(root, path)
end

function Base.rm(root::AbstractFileSystemRoot, path::RelPath; kws...)
    rm(_abspath(root,path); kws...)
end

Base.readdir(root::AbstractFileSystemRoot, path::RelPath) = readdir(_abspath(root, path))

#--------------------------------------------------
struct FileSystemRoot <: AbstractFileSystemRoot
    path::String
    read::Bool
    write::Bool
end

function FileSystemRoot(path::AbstractString; write=false, read=true)
    path = abspath(path)
    FileSystemRoot(path, read, write)
end

iswriteable(root::FileSystemRoot) = root.write

_abspath(root::FileSystemRoot) = root.path


#--------------------------------------------------
# Infrastructure for a somewhat more functional interface for creating file
# trees than the fully mutable version we usually use.

mutable struct TempFilesystemRoot <: AbstractFileSystemRoot
    path::Union{Nothing,String}
    function TempFilesystemRoot(path)
        root = new(path)
        finalizer(root) do r
            if !isnothing(r.path)
                rm(r.path, recursive=true, force=true)
            end
        end
        return root
    end
end

function Base.readdir(root::TempFilesystemRoot, path::RelPath)
    return isnothing(root.path) ? [] : readdir(_abspath(root, path))
end

iswriteable(root::TempFilesystemRoot) = true
_abspath(root::TempFilesystemRoot) = root.path

function newdir(ctx::AbstractFileSystemRoot=FileSystemRoot(tempdir(), write=true))
    # cleanup=false: we manage our own cleanup via the finalizer
    path = mktempdir(_abspath(ctx), cleanup=false)
    return BlobTree(TempFilesystemRoot(path))
end
newdir(ctx::BlobTree) = newdir(ctx.root)

function newfile(ctx::AbstractFileSystemRoot=FileSystemRoot(tempdir(), write=true))
    path, io = mktemp(_abspath(ctx), cleanup=false)
    close(io)
    return Blob(TempFilesystemRoot(path))
end
newfile(ctx::BlobTree) = newfile(ctx.root)

function newfile(f::Function, ctx=FileSystemRoot(tempdir(), write=true))
    path, io = mktemp(_abspath(ctx), cleanup=false)
    try
        f(io)
    catch
        rm(path)
        rethrow()
    finally
        close(io)
    end
    return Blob(TempFilesystemRoot(path))
end

# Move srcpath to destpath, making all attempts to preserve the original
# content of `destpath` if anything goes wrong. We assume that `srcpath` is
# temporary content which doesn't need to be protected.
function mv_force_with_dest_rollback(srcpath, destpath, tempdir_parent)
    holding_area = nothing
    held_path = nothing
    if ispath(destpath)
        # If the destination path exists, improve the atomic nature of the
        # update by first moving existing data to a temporary directory.
        holding_area = mktempdir(tempdir_parent, prefix="jl_to_remove_", cleanup=false)
        name = basename(destpath)
        held_path = joinpath(holding_area,name)
        mv(destpath, held_path)
    end
    try
        mv(srcpath, destpath)
    catch
        try
            if !isnothing(holding_area)
                # Attempt to put things back as they were!
                mv(held_path, destpath)
            end
        catch
            # At this point we've tried our best to preserve the user's data
            # but something has gone wrong, likely at the OS level. The user
            # will have to clean up manually if possible.
            error("""
                  Something when wrong while moving data to path $destpath.

                  We tried restoring the original data to $destpath, but were
                  met with another error. The original data is preserved in
                  $held_path

                  See the catch stack for the root cause.
                  """)
        end
        rethrow()
    end
    if !isnothing(holding_area)
        # If we get to here, it's safe to remove the holding area
        rm(holding_area, recursive=true)
    end
end

function Base.setindex!(tree::BlobTree{<:AbstractFileSystemRoot},
                        tmpdata::Union{Blob{TempFilesystemRoot},BlobTree{TempFilesystemRoot}},
                        name::AbstractString)
    if !iswriteable(tree.root)
        error("Attempt to move to a read-only tree $tree")
    end
    if isnothing(tmpdata.root.path)
        type = isdir(tmpdata) ? "directory" : "file"
        error("Attempted to root a temporary $type which has already been moved to $(tree.path)/$name ")
    end
    if !isempty(tree.path)
        # Eh, the number of ways the user can misuse this isn't really funny :-/
        error("Temporary trees must be moved in full. The tree had non-empty path $(tree.path)")
    end
    destpath = _abspath(joinpath(tree, name))
    srcpath = _abspath(tmpdata)
    tempdir_parent = _abspath(tree)
    mv_force_with_dest_rollback(srcpath, destpath, tempdir_parent)
    # Transfer ownership of the data to `tree`. This is ugly to be sure, as it
    # leaves `tmpdata` empty! However, we'll have to live with this wart unless
    # we want to be duplicating large amounts of data on disk.
    tmpdata.root.path = nothing
    return tree
end

# It's interesting to read about the linux VFS interface in regards to how the
# OS actually represents these things. For example
# https://stackoverflow.com/questions/36144807/why-does-linux-use-getdents-on-directories-instead-of-read




#--------------------------------------------------

function connect_filesystem(f, config)
    path = config["path"]
    type = config["type"]
    if type == "Blob"
        isfile(path) || throw(ArgumentError("$(repr(path)) should be a file"))
        storage = Blob(FileSystemRoot(path))
    elseif type == "BlobTree"
        isdir(path)  || throw(ArgumentError("$(repr(path)) should be a directory"))
        storage = BlobTree(FileSystemRoot(path))
    else
        throw(ArgumentError("DataSet type $type not supported on the filesystem"))
    end
    f(storage)
end
_drivers["FileSystem"] = connect_filesystem

