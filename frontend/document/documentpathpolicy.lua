--[[--
Central document path policy for the hardened offline iOS build.
]]--

local Device = require("device")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local DocumentPathPolicy = {}

local function getCanonicalBooksRoot()
    return ffiUtil.realpath(Device.home_dir or ".")
end

local function hasSymlinkComponent(path, root)
    if type(path) ~= "string" or path == "" or not root then return true end
    local current = path:gsub("/+$", "")
    while current ~= "" do
        if lfs.symlinkattributes(current, "mode") == "link" then
            return true
        end
        if current == root then return false end
        local parent = ffiUtil.dirname(current)
        if not parent or parent == current then break end
        current = parent:gsub("/+$", "")
    end
    return true
end

function DocumentPathPolicy:getBooksRoot()
    return getCanonicalBooksRoot() or Device.home_dir or "."
end

function DocumentPathPolicy:isPathInsideBooks(path)
    if not Device:isHardenedOffline() then
        return true
    end
    local root = getCanonicalBooksRoot()
    if hasSymlinkComponent(path, root) then return false end
    local canonical = path and ffiUtil.realpath(path)
    return root ~= nil
        and canonical ~= nil
        and (canonical == root or util.stringStartsWith(canonical, root .. "/"))
end

function DocumentPathPolicy:isBooksRoot(path)
    if not Device:isHardenedOffline() then
        return false
    end
    local root = getCanonicalBooksRoot()
    return root ~= nil and path ~= nil
        and not hasSymlinkComponent(path, root)
        and ffiUtil.realpath(path) == root
end

function DocumentPathPolicy:constrainToBooks(path)
    if not Device:isHardenedOffline() then
        return ffiUtil.realpath(path)
    end
    if self:isPathInsideBooks(path) then
        return ffiUtil.realpath(path)
    end
    return self:getBooksRoot()
end

function DocumentPathPolicy:resolveExistingPath(path)
    if not Device:isHardenedOffline() then
        return path
    end
    if not self:isPathInsideBooks(path) then return nil end
    return ffiUtil.realpath(path)
end

DocumentPathPolicy.resolveDocument = DocumentPathPolicy.resolveExistingPath

function DocumentPathPolicy:resolveMutablePath(path)
    if not Device:isHardenedOffline() then
        return path and ffiUtil.realpath(path)
    end
    local canonical = self:resolveExistingPath(path)
    if canonical and not self:isBooksRoot(canonical) then
        return canonical
    end
end

function DocumentPathPolicy:resolveWritePath(path)
    if not Device:isHardenedOffline() then
        return path
    end
    if not path then return end
    local root = getCanonicalBooksRoot()
    if hasSymlinkComponent(path, root) then return end

    local canonical = ffiUtil.realpath(path)
    if canonical then
        return self:isPathInsideBooks(path) and canonical or nil
    end

    local parent = ffiUtil.realpath(ffiUtil.dirname(path))
    if parent and self:isPathInsideBooks(parent) then
        return ffiUtil.joinPath(parent, ffiUtil.basename(path))
    end
end

return DocumentPathPolicy
