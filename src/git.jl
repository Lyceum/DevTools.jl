using GitHub
using JSON
using GitHub: authenticate_headers!, AnonymousAuth, github2json, api_uri, GitHubAPI
import HTTP

function repository_dispatch(
    repo,
    event_type::AbstractString = "dispatch";
    client_payload::Dict = Dict(),
    kwargs...,
)
    headers = Dict(
        "Accept" => "application/vnd.github.everest-preview+json",
        "Content-Type" => "application/json",
    )
    params = Dict("event_type" => event_type, "client_payload" => client_payload)
    result = GitHub.github_request(
        GitHub.DEFAULT_API,
        HTTP.post,
        "/repos/$(GitHub.name(repo))/dispatches";
        headers = headers, params = params, kwargs...,
    )
end

treehash(pkgdir::String) = Base.SHA1(Pkg.GitTools.tree_hash(pkgdir))
treehash(pkg::Module) = treehash(pkgdir(pkg))

function githttpsurl(url::AbstractString)
    m = match(LibGit2.URL_REGEX, url)
    LibGit2.git_url(scheme = "https", host = m[:host], path = m[:path])
end

function create_git_cmd(gitconfig::Pair...; path = nothing)
    cmd = isnothing(path) ? ["git"] : ["git", "-C", path]
    for (n, v) in gitconfig
        push!(cmd, "-c")
        push!(cmd, "$n=$v")
    end
    Cmd(cmd)
end

function pushrepo(repodir::String)
    git = create_git_cmd(path = repodir)
    cmd = `$git push`
    @info "Running $cmd"
    run(cmd)
end

function pushrepo(pkg::Module, args...; kwargs...)
    d = pkgdir(pkg)
    pushrepo(d, args...; kwargs...)
end

isdirty(repo_path::AbstractString) = LibGit2.isdirty(LibGit2.GitRepo(repo_path))

function get_remote_from_registres(package_path::AbstractString)
    # Try to find remote repo in registries
    ctx = Pkg.Types.Context()
    Pkg.Types.clone_default_registries()
    Pkg.Types.update_registries(ctx; force=true)
    uuid = Pkg.Types.read_package(Pkg.Types.projectfile_path(package_path)).uuid
    Pkg.Types.registered_info(ctx.env, uuid, "repo")[2]
end

function get_remote_from_local_repo(package_path, https=true)
    repo = GitRepo(package_path)
    remoteurl = LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo, LibGit2.Consts.REMOTE_ORIGIN)) do remote
        LibGit2.url(remote)
    end
    https ? DevTools.githttpsurl(remoteurl) : remoteurl
end

function get_remote(package_path::AbstractString)
    try
        get_remote_from_registres(package_path)
    catch
        try
            get_remote_from_local_repo(package_path)
        catch
            throw(ArgumentError("Could not find remote URL"))
        end
    end
end