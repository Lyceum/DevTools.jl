const LYCEUM_REGISTRY = RegistrySpec(
    uuid = "96ca1a0e-015d-46b7-a12d-07d1320642ca",
    name = "LyceumRegistry",
    url = "https://github.com/Lyceum/LyceumRegistry.git",
)

const GENERAL_REGISTRY = RegistrySpec(
    uuid = "23338594-aafe-5451-b93e-139f81909106",
    name = "General",
    url = "https://github.com/JuliaRegistries/General.git",
)

const LYCEUM_PKGTEMPLATE = (
    user = "Lyceum",
    host = "github.com",
    license = "BSD3",
    authors = ["Colin Summers"],
    ssh = true,
    manifest = true,
    julia_version = VERSION,
    dev = false,
)


function namedgenerate(pkgname::String, preset::NamedTuple = LYCEUM_PKGTEMPLATE; kwargs...)
    push!(preset.authors, "The Contributors of $pkgname")
    t = Template(; preset..., kwargs...)
    generate(pkgname, t)
end

function lyceum_register(package_repo, commit, lyceumbot_pat)
    register(package_repo, commit, LYCEUM_REGISTRY.url, GitHub.authenticate(lyceumbot_pat), "lycuembot")
end

function register(package_repo::AbstractString, commit::AbstractString, registry::AbstractString, auth::GitHub.Authorization, gituser::AbstractString; ignore_dirty::Bool=false, kwargs...)
    try
        Base.SHA1(commit)
    catch e
        throw(ArgumentError("\"$commit\" is not a valid SHA-1"))
    end

    package_repo = githttpsurl(package_repo) # always register https url

    cdtempdir() do
        gitconfig=Dict("user.name"=>gituser, "user.password"=>auth.token)
        git = DevTools.create_git_cmd(pairs(gitconfig)...)

        run(`$git clone $package_repo $(pwd())`)
        run(`$git checkout master`)
        success(`$git merge-base --is-ancestor $commit HEAD`) || error("$commit not found in master branch")
        run(`$git checkout $commit`)

        pkg = Pkg.Types.read_project(Pkg.Types.projectfile_path(pwd()))
        tree_hash = bytes2hex(Pkg.GitTools.tree_hash(pwd()))
        registry_deps = map(reg->reg.url, Pkg.Types.collect_registries())
        if !(registry in registry_deps)
            error("$registry not found in local registries")
        end

        rbrn = RegistryTools.register(package_repo, pkg, tree_hash; kwargs..., registry=registry, registry_deps=registry_deps, gitconfig=gitconfig, push=true, branch="master")
        haskey(rbrn.metadata, "error") && error(rbrn.metadata["error"])

        #name = rbrn.name
        #ver = rbrn.version
        #brn = rbrn.branch
        #meta = rbrn.metadata

        #repo = GitHub.repo(join(split(splitext(registry)[1], "/")[end-1:end], "/"), auth=auth)
        #params = Dict(
        #    "base"=>"master",
        #    "head"=>brn,
        #    "maintainer_can_modify"=>true,
        #    "title"=> "$(rbrn.metadata["kind"]): $name v$ver",
        #)
        #haskey(meta, "labels") && (params["labels"] = meta["labels"])
        #body = IOBuffer()
        #write(body, "Commit: $commit")
        #if get(rbrn.metadata, "warning", nothing) !== nothing
        #    write(body,
        #        """
        #        Warning: $(rbrn.metadata["warning"])
        #        This can be safely ignored. However, if you want to fix this you can do so. Call register() again after making the fix. This will update the Pull request.
        #        """
        #    )
        #end
        #params["body"] = String(take!(body))

        #pr, msg = create_or_find_pull_request(repo, auth, params)

        #return pr, rbrn
        return rbrn
    end
end


function create_or_find_pull_request(repo::GitHub.Repo, auth::GitHub.Authorization, params::Dict{<:AbstractString, Any})
    pr = nothing
    msg = ""
    try
        pr = GitHub.create_pull_request(repo; auth=auth, params=params)
        msg = "created"
        @debug("Pull request created")
    catch ex
        if is_pr_exists_exception(ex)
            @debug("Pull request already exists, not creating")
            msg = "updated"
        else
            rethrow(ex)
        end
    end

    if pr === nothing
        prs, _ = GitHub.pull_requests(repo; auth=auth, params=Dict(
            "state" => "open",
            "base" => params["base"],
            "head" => string(repo.owner.login, ":", params["head"]),
        ))
        if !isempty(prs)
            @assert length(prs) == 1 "PR lookup should only contain one result"
            @debug("PR found")
            pr = prs[1]
        end

        if pr === nothing
            error("PR already exists but unable to find it")
        else
            GitHub.update_pull_request(repo, pr; auth=auth, params=params)
        end
    end

    try # update labels
        if haskey(params, "labels")
            GitHub.edit_issue(repo, pr; auth = auth, params = Dict("labels"=>params["labels"]))
        end
    catch
        @debug "Failed to update labels, ignoring."
    end

    return pr, msg
end

function parse_github_exception(ex::ErrorException)
    msgs = map(strip, split(ex.msg, '\n'))
    d = Dict()
    for m in msgs
        a, b = split(m, ":"; limit=2)
        d[a] = strip(b)
    end
    return d
end

function is_pr_exists_exception(ex)
    d = parse_github_exception(ex)

    if d["Status Code"] == "422" &&
       match(r"A pull request already exists", d["Errors"]) !== nothing
        return true
    end

    return false
end


incrementversion!(pkg::Module, args...; kwargs...) =
    incrementversion!(pkgdir(pkg), args...; kwargs...)
function incrementversion!(pkgdir::String, args...; tag::Bool = false, kwargs...)
    isdirty(pkgdir) && error("$pkgdir is dirty")

    toml = parsetomls(pkgdir).project.dict
    newver = incrementversion(toml["version"], args...; kwargs...)
    toml["version"] = newver
    tomlpath = Pkg.Operations.projectfile_path(pkgdir)
    @info "Writing to $tomlpath"
    open(tomlpath, "w") do io
        Pkg.TOML.print(io, toml)
    end

    git = create_git_cmd(path = pkgdir)
    run(`$git add Project.toml`)
    message = "New version: v$(newver)"
    run(`$git commit -qm $message`)

    pkgdir
end
function incrementversion(
    version::Union{String,VersionNumber},
    which::Symbol;
    prerelease = :keep,
)
    v = version isa String ? VersionNumber(version) : version
    major = v.major
    minor = v.minor
    patch = v.patch
    pre = v.prerelease
    build = v.build

    build != () && @warn "Build not empty: $build"

    if which === :major
        major += 1
        minor = 0
        patch = 0
    elseif which === :minor
        minor += 1
        patch = 0
    elseif which === :patch
        patch += 1
    else
        error("which must be :major, :minor, or :patch. Got $which")
    end

    if prerelease === :keep
        nothing
    elseif prerelease === :dev
        pre = ("DEV",)
    elseif isnothing(prerelease)
        pre = ()
    else
        error("prerlease must be one of :keep, :dev, or nothing")
    end

    vnew = VersionNumber(major, minor, patch, pre, build)
    @info "Old version: $v. New version: $vnew"
    vnew
end

function isversionlatest(pkg::Module)
    project = parsetomls(pkgdir(pkg)).project.dict
    localver = VersionNumber(project["version"])
    latestver = latestversion(pkg)
    return isnothing(latestversion) || localver > latestver
end

latestversion(pkg::Module) = latestversion(UUID(parsetomls(pkgdir(pkg)).project.dict["uuid"]))
function latestversion(uuid::UUID)
    Pkg.Registry.update()
    registries = Pkg.Types.collect_registries()
    for reg in registries
        packages = Pkg.Types.read_registry(joinpath(reg.path, "Registry.toml"))["packages"]
        if haskey(packages, string(uuid))
            package_path = joinpath(reg.path, packages[string(uuid)]["path"])
            versions = collect(keys(Pkg.Operations.load_versions(package_path)))
            sort!(versions)
            return versions[end]
        end
    end
    nothing
end
