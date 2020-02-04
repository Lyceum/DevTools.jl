module Compat

using Pkg, GitHub, Dates
using ..DevTools: create_git_cmd, with_sandbox_env, parsetomls
using Pkg.Types: VersionSpec, semver_spec

const BASE_PACKAGES = Set{Base.UUID}(x for x in keys(Pkg.Types.stdlib()))

const COMPAT_UUID = "0062fa4e-0639-437d-8ed2-9da17d9c0af2"

const DEFAULT_MASTERBRANCH = "master"
const DEFAULT_COMPATBRANCH = "compat"

const DEF_KEEP_OLD_COMPAT = false
const DEF_UPDATE_MANIFEST = true
const DEF_DROP_PATCH = true

Base.@kwdef struct RepoSpec
    token::String
    username::String
    useremail::String
    reponame::String
    masterbranch::String
    compatbranch::String
end

function ghactions(;kwargs...)
    spec = RepoSpec(
        token = ENV["COMPAT_TOKEN"],
        username = ENV["COMPAT_USERNAME"],
        useremail = ENV["COMPAT_USEREMAIL"],
        reponame = ENV["GITHUB_REPOSITORY"],
        masterbranch = haskey(ENV, "COMPAT_MASTERBRANCH") ? ENV["COMPAT_MASTERBRANCH"] : DEFAULT_MASTERBRANCH,
        compatbranch = haskey(ENV, "COMPAT_COMPATBRANCH") ? ENV["COMPAT_COMPATBRANCH"] : DEFAULT_COMPATBRANCH,
    )
    update_tomls!(spec; kwargs...)
end

function update_tomls!(
    repospec::RepoSpec;
    keep_old_compat::Bool = DEF_KEEP_OLD_COMPAT,
    update_manifest::Bool = DEF_UPDATE_MANIFEST,
    drop_patch::Bool = DEF_DROP_PATCH,
)
    token = repospec.token
    reponame = repospec.reponame
    username = repospec.username
    useremail = repospec.useremail
    masterbranch = repospec.masterbranch
    compatbranch = repospec.compatbranch
    gitcmd = create_git_cmd("user.name" => username, "user.email" => useremail)

    old_dir = pwd()
    tmp_dir = tempname()
    try
        auth = GitHub.authenticate(repospec.token)
        ghrepo = GitHub.repo(reponame, auth = auth)
        existing_pr = find_existing_pr(ghrepo, auth)

        url = authurl(username, token, reponame)
        #url = authurl(token, reponame)
        run(`$gitcmd clone $url $tmp_dir`)
        cd(tmp_dir)

        run(`$gitcmd checkout $masterbranch`)
        run(`$gitcmd pull`)
        run(`$gitcmd checkout -B $compatbranch`)  # overwrite existing compat branch if it exists

        result = update_tomls!(
            pwd(),
            keep_old_compat = keep_old_compat,
            update_manifest = update_manifest,
            drop_patch = drop_patch
        )


        if update_manifest
            manifest = Pkg.Types.manifestfile_path(pwd(), strict = true)
            !isnothing(manifest) && run(`$gitcmd add $manifest`)
        end
        project = Pkg.Types.projectfile_path(pwd(), strict=true)
        !isnothing(project) && run(`$gitcmd add $project`)

        if success(`$gitcmd diff --cached --exit-code`)
            @info "Done. No changes made."
            return
        elseif success(`$gitcmd ls-remote --exit-code --heads origin $compatbranch`)
            if success(`$gitcmd diff --cached origin/$compatbranch --exit-code`)
                @info "Done. No changes made (relative to origin/$compatbranch)"
                return
            end
        end


        title = "New compat entries"
        body = format_message(result)
        @info title
        @info body
        run(`$gitcmd commit -m $title`)
        run(`$gitcmd push --force -u origin $compatbranch`)

        params = Dict()
        params["title"] = title
        params["base"] = masterbranch
        params["head"] = compatbranch
        params["body"] = body
        params["labels"] = ["nochangelog", "compat"]
        if isnothing(existing_pr)
            pr = GitHub.create_pull_request(ghrepo; params = params, auth = auth)
            GitHub.edit_issue(
                ghrepo,
                pr,
                params = Dict("labels" => ["nochangelog", "compat"]),
                auth = auth,
            )
        else
            params = Dict()
            params["body"] = body
            params["labels"] = ["nochangelog", "compat"]
            GitHub.edit_issue(ghrepo, existing_pr, params = params, auth = auth)
        end
    catch e
        rethrow(e)
    finally
        cd(old_dir)
        rm(tmp_dir, force = true, recursive = true)
    end
end

function find_existing_pr(repo::GitHub.Repo, auth::GitHub.Authorization)
    params = Dict("state" => "open", "per_page" => 100, "page" => 1)
    prs, page_data =
        GitHub.pull_requests(repo; auth = auth, params = params, page_limit = 100)
    compat_prs = Vector{GitHub.PullRequest}()
    while true
        for pr in prs
            if occursin(COMPAT_UUID, pr.body)
                push!(compat_prs, pr)
            end
        end
        if haskey(page_data, "next")
            prs, page_data = GitHub.pull_requests(
                repo;
                auth = auth, page_limit = 100, start_page = page_data["next"],
            )
        else
            break
        end
    end
    if isempty(compat_prs)
        return nothing
    elseif length(compat_prs) == 1
        return first(compat_prs)
    else
        throw(ErrorException("More than one compat PR found"))
    end
end



function format_message(result)
    r = result
    io = IOBuffer()
    r.added_compat_section && println(io, "Added new compat section  $(now())")
    !isnothing(r.new_julia_compat) &&
    println(io, "Added compat entry for Julia: $(r.new_julia_compat)")
    if !isempty(r.multiple_entries)
        println(io, "\nSkipped due to multiple entries with the same name:")
        for (name, uuids) in r.multiple_entries
            indented_println(io, name)
            for uuid in uuids
                indented_println(io, uuid, indents = 2)
            end
        end
    end
    if !isempty(r.bad_version)
        println(io, "\nSkipped due to version having build or prerelease specifier:")
        for (name, version) in r.multiple_entries
            indented_println(io, "$name: $version")
        end
    end
    if !isempty(r.new)
        println(io, "\nNew compat entries:")
        for (name, compat) in r.new
            indented_println(io, "$name: $compat")
        end
    end
    if !isempty(r.changed)
        println(io, "\nChanged compat entries:")
        for (name, old, new) in r.changed
            indented_println(io, "$name: $old    =>    $new")
        end
    end
    if !isempty(r.unchanged)
        println(io, "\nUnchanged compat entries:")
        for (name, compat) in r.unchanged
            indented_println(io, "$name: $compat")
        end
    end
    println(io, '\n', repeat('_', 80))
    println(io, COMPAT_UUID)
    String(take!(io))
end


function update_tomls!(
    pkgdir::AbstractString;
    keep_old_compat = DEF_KEEP_OLD_COMPAT,
    update_manifest = DEF_UPDATE_MANIFEST,
    drop_patch = DEF_DROP_PATCH,
)
    result = _update_tomls!(pkgdir, keep_old_compat, update_manifest, drop_patch)
    msg = format_message(result)
    result
end

function _update_tomls!(
    pkgdir::AbstractString,
    keep_old_compat::Bool,
    update_manifest::Bool,
    drop_patch::Bool
)
    old_tomls = get_old_tomls(pkgdir)
    updated_tomls = get_updated_tomls(pkgdir)
    old_project = old_tomls.project.dict
    old_manifest = old_tomls.manifest.dict
    updated_project = updated_tomls.project.dict
    updated_manifest = updated_tomls.manifest.dict
    @assert old_project["deps"] == updated_project["deps"]

    io = IOBuffer()

    keep_old_compat && println(io, "Keeping Old compat entries")
    update_manifest && println(io, "Updating Manifest")

    hascompat = haskey(old_project, "compat")
    if !hascompat
        old_project["compat"] = Dict{Any,Any}()
        updated_project["compat"] = Dict{Any,Any}()
    end

    hasjuliacompat = hascompat && haskey(old_project["compat"], "julia")
    if !hasjuliacompat
        julia_compat = format_compat(VERSION, drop_patch)
        updated_project["compat"]["julia"] = julia_compat
    end

    unchanged_compats = Tuple{String,String}[] # (name, old_compat)
    changed_compats = Tuple{String,String,String}[] # (name, old_compat, new_compat)
    new_compats = Tuple{String,String}[] # (name, new_compat)
    multiple_entries = Tuple{String,Vector{String}}[] # (name, UUIDs)
    bad_version = Tuple{String,VersionNumber}[] # (name, version)

    for (name, uuid) in pairs(old_project["deps"])
        (isstdlib(uuid) || isjll(name)) && continue

        if length(updated_manifest[name]) > 1
            entries = updated_manifest[name]
            push!(multiple_entries, (name, map(x -> x["uuid"], entries)))
            continue
        end

        old_version = VersionNumber(first(old_manifest[name])["version"])
        new_version = VersionNumber(first(updated_manifest[name])["version"])
        if !no_prerelease_or_build(new_version)
            push!(bad_version, (name, new_version))
            continue
        end

        if haskey(old_project["compat"], name)
            old_compat = format_compat(old_project["compat"][name], drop_patch)
            if VersionSpec(semver_spec(old_compat)) == VersionSpec(semver_spec(string(new_version)))
                new_compat = old_compat
                push!(unchanged_compats, (name, old_compat))
            elseif majorminorequal(old_compat, string(new_version))
                new_compat = format_compat(new_version, drop_patch)
                push!(changed_compats, (name, old_compat, new_compat))
            else
                if keep_old_compat
                    new_compat = format_compat(old_compat, new_version, drop_patch)
                else
                    new_compat = format_compat(new_version, drop_patch)
                end
                push!(changed_compats, (name, old_compat, new_compat))
            end
        else
            new_compat = format_compat(new_version, drop_patch)
            push!(new_compats, (name, new_compat))
        end
        updated_project["compat"][name] = new_compat
    end

    # check compats
    for (name, compat) in pairs(updated_project["compat"])
        try
            @assert VersionSpec(semver_spec(compat)) isa VersionSpec
        catch
            error("Invalid compat $compat for $name")
        end
    end

    result = (
        added_compat_section = !hascompat,
        new_julia_compat = hasjuliacompat ? nothing : julia_compat,
        unchanged = unchanged_compats,
        changed = changed_compats,
        new = new_compats,
        multiple_entries = multiple_entries,
        bad_version = bad_version,
    )

    project_filename = basename(Pkg.Operations.projectfile_path(pkgdir, strict = true))
    open(joinpath(pkgdir, project_filename), "w") do io
        Pkg.TOML.print(
            io,
            updated_project,
            sorted = true,
            by = key -> (Pkg.Types.project_key_order(key), key),
        )
    end

    if update_manifest
        manifestpath = Pkg.Operations.manifestfile_path(pkgdir, strict = true)
        if !isnothing(manifestpath)
            open(joinpath(pkgdir, basename(manifestpath)), "w") do io
                Pkg.TOML.print(io, updated_manifest)
            end
        end
    end

    return result
end

function indented_println(io::IOBuffer, xs...; indents = 1)
    for _ = 1:(Base.indent_width*indents)
        print(io, " ")
    end
    println(io, xs...)
end

function get_old_tomls(pkgdir)
    with_sandbox_env(pkgdir) do
        # Create/resolve manifest if one doesn't already exist,
        Pkg.instantiate()
        Pkg.resolve()
        return parsetomls(pwd())
    end
end

function get_updated_tomls(pkgdir::AbstractString)
    with_sandbox_env(pkgdir) do
        tomls = parsetomls(pwd())
        if haskey(tomls.project.dict, "compat")
            for pkg in keys(tomls.project.dict["compat"])
                pkg != "julia" && delete!(tomls.project.dict["compat"], pkg)
            end
        end

        manifestpath = Pkg.Operations.manifestfile_path(pwd(), strict = true)
        projectpath = Pkg.Operations.projectfile_path(pwd(), strict = true)

        open(projectpath, "w") do io
            Pkg.TOML.print(io, tomls.project.dict)
        end
        Pkg.instantiate()
        Pkg.resolve()
        Pkg.update()
        return parsetomls(pwd())
    end
end


isstdlib(name::AbstractString) = isstdlib(Base.UUID(name))
isstdlib(uuid::Base.UUID) = uuid in BASE_PACKAGES
isjll(name::AbstractString) = endswith(lowercase(strip(name)), lowercase(strip("_jll"))) # TODO check for Artifacts.toml?

no_prerelease_or_build(v::VersionNumber) = v.build == v.prerelease == ()
no_prerelease_or_build(v) = no_prerelease_or_build(VersionNumber(v))


function format_compat(v::VersionNumber, drop_patch::Bool)
    no_prerelease_or_build(v) ||
    throw(ArgumentError("version cannot have build or prerelease. Got: $v"))
    if v.patch == 0 || drop_patch
        if v.minor == 0
            if v.major == 0 # v.major is 0, v.minor is 0, v.patch is 0
                throw(DomainError("0.0.0 is not a valid input"))
            else # v.major is nonzero and v.minor is 0 and v.patch is 0
                return "$(v.major)"
            end
        else # v.minor is nonzero, v.patch is 0
            return "$(v.major).$(v.minor)"
        end
    else # v.patch is nonzero
        return "$(v.major).$(v.minor).$(v.patch)"
    end
end

function format_compat(compat::AbstractString, drop_patch::Bool)
    compat = String(compat)
    try
        return format_compat(VersionNumber(compat))
    catch
        try
            spec = Pkg.Types.VersionSpec(Pkg.Types.semver_spec(compat)) # check to make sure valid
            @assert spec isa VersionSpec
            return String(strip(compat))
        catch
            throw(ArgumentError("not a valid compat entry: $compat"))
        end
    end
end

function majorminorequal(x::AbstractString, y::AbstractString)
    x = String(strip(x))
    y = String(strip(y))
    if startswith(x, '^')
        x = String(strip(split(x, '^')[2]))
    end
    if startswith(y, '^')
        y = String(strip(split(y, '^')[2]))
    end
    try
        xver = VersionNumber(x)
        yver = VersionNumber(y)
        return xver.major == yver.major && xver.minor == yver.minor
    catch
        return false
    end
end


function format_compat(old, new, drop_patch)
    "$(format_compat(old, drop_patch)), $(format_compat(new, drop_patch))"
end


authurl(user, token, fullname) =
    url_with_auth = "https://$(user):$(token)@github.com/$(fullname).git"

end # module
