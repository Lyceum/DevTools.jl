const JLFORMATARGS =
    (indent = 4, margin = 92, overwrite = true, verbose = false, always_for_in = false)

function format_file(file::AbstractString; kwargs...)
    JuliaFormatter.format_file(file; JLFORMATARGS..., kwargs...)
end

function format(paths...; kwargs...)
    JuliaFormatter.format(paths...; JLFORMATARGS..., kwargs...)
end

function format(pkg::Module; kwargs...)
    JuliaFormatter.format(pkgdir(pkg); JLFORMATARGS..., kwargs...)
end


cdtempdir(f) = mktempdir(dir->cd(f, dir))

# copied from Documenter.jl
function genkeys(; user = "\$USER", repo = "\$REPO", comment = "lyceumdevs@gmail.com")
    # Error checking. Do the required programs exist?
    success(`which which`) || error("'which' not found.")
    success(`which ssh-keygen`) || error("'ssh-keygen' not found.")

    directory = pwd()
    filename = tempname()

    isfile(filename) &&
    error("temporary file '$(filename)' already exists in working directory")
    isfile("$(filename).pub") &&
    error("temporary file '$(filename).pub' already exists in working directory")

    # Generate the ssh key pair.
    success(`ssh-keygen -N "" -C $comment -f $filename`) ||
    error("failed to generate a SSH key pair.")

    # Prompt user to add public key to github then remove the public key.
    let url = "https://github.com/$user/$repo/settings/keys"
        @info("add the public key below to $url with read/write access:")
        println("\n", read("$filename.pub", String))
        rm("$filename.pub")
    end

    # Base64 encode the private key and prompt user to add it to travis. The key is
    # *not* encoded for the sake of security, but instead to make it easier to
    # copy/paste it over to travis without having to worry about whitespace.
    let travis_url = "https://travis-ci.com/$user/$repo/settings",
        github_url = "https://github.com/$user/$repo/settings/secrets"

        @info(
            "add a secure environment variable named to " *
            "$(travis_url) (if you deploy using Travis CI) or " *
            "$(github_url) (if you deploy using GitHub Actions) with value:"
        )
        println("\n", base64encode(read(filename, String)), "\n")
        rm(filename)
    end
end

function snooppkg(pkg::Module; overwrite::Bool = false) #flags::Vector{String}=String[])
    @warn "Switch to using snoopi"

    d = pkgdir(pkg)
    name = nameof(pkg)
    flags = ["--project=$d"]
    precompfile = joinpath(d, "src", "precompile.jl")
    logfile = "/tmp/$(name)_snoop.log"
    if isfile(precompfile) && !overwrite
        error("$precompfile already exists but overwrite was false")
    end

    ex = quote
        using $name
        include(joinpath($d, "test", "runtests.jl"))
    end

    SnoopCompile.snoopc(flags, logfile, ex)
    data = SnoopCompile.read(logfile)
    pc = SnoopCompile.parcel(reverse!(data[2]))
    SnoopCompile.write("/tmp/precompile", pc)
    cp("/tmp/precompile/precompile_$(name).jl", precompfile)
end


regspec(reg::RegistrySpec) = regspec(reg.uuid, name=reg.name, url=reg.url, path=reg.path)
function regspec(uuid::UUID)
    registries = Pkg.Types.collect_registries()
    idx = findfirst(r -> r.uuid == uuid, registries)
    isnothing(idx) ? nothing : registries[idx]
end

function regspec(uuid; name = nothing, url = nothing, path = nothing)
    uuid = isa(uuid, UUID) ? uuid : UUID(uuid)
    spec = regspec(uuid)
    if isnothing(spec)
        isnothing(name) ||
        isnothing(url) || isnothing(path) && error("Registry not found. Must specify spec")
        return RegistrySpec(uuid = uuid, name = name, url = url, path = path)
    else
        return RegistrySpec(
            name = isnothing(spec.name) ? name : spec.name,
            uuid = isnothing(spec.uuid) ? uuid : spec.uuid,
            url = githttpsurl(isnothing(spec.url) ? url : spec.url),
            path = isnothing(spec.path) ? path : spec.path,
        )
    end
end


pkgdir(pkg::Module) = normpath(joinpath(dirname(Base.pathof(pkg)), ".."))

hasmanifest(pkgdir::String) = !isnothing(Pkg.Operations.manifestfile_path(pkgdir, strict=true))
hasproject(pkgdir::String) = !isnothing(Pkg.Operations.projectfile_path(pkgdir, strict=true))

function parsetomls(pkgdir::String)
    manifestpath = Pkg.Operations.manifestfile_path(pkgdir, strict = true)
    projectpath = Pkg.Operations.projectfile_path(pkgdir, strict = true)
    (project = _parsetoml(projectpath), manifest = _parsetoml(manifestpath))
end
function _parsetoml(tomlpath)
    if isnothing(tomlpath) || !isfile(tomlpath)
        return nothing
    else
        string = read(tomlpath, String)
        (path = tomlpath, string = string, dict = Pkg.TOML.parse(string))
    end
end


function with_sandbox_env(
    fn::Function,
    project::AbstractString = Base.active_project();
    copyall::Bool = false,
    extra_load_paths::Vector{<:AbstractString} = AbstractString[],
    default_load_path = false,
    tempdir = true
)
    if isdir(project)
        project = Pkg.Operations.projectfile_path(project, strict = true)
        isnothing(project) && throw(ArgumentError("No project file found in $project"))
    end

    old_dir = pwd()
    old_load_path = copy(LOAD_PATH)
    old_project = Base.active_project()

    mktempdir() do sandbox
        if copyall
            cpinto(dirname(project), sandbox)
        else
            manifest = Pkg.Operations.manifestfile_path(dirname(project), strict = true)
            !isnothing(manifest) && cp(manifest, joinpath(sandbox, basename(manifest)))
            cp(project, joinpath(sandbox, basename(project)))
        end

        try
            cd(sandbox)
            if default_load_path
                empty!(LOAD_PATH)
                Base.init_load_path()
            end
            Pkg.activate(pwd())
            append!(LOAD_PATH, map(normpath, extra_load_paths))
            return fn()
        finally
            cd(old_dir)
            append!(empty!(LOAD_PATH), old_load_path)
            Pkg.activate(old_project)
        end
    end
end

function cpinto(srcdir::AbstractString, dstdir::AbstractString)
    isdir(srcdir) || throw(ArgumentError("Expected a directory for `srcdir`, got $srcdir"))
    isdir(dstdir) || throw(ArgumentError("Expected a directory for `dstdir`, got $dstdir"))
    for file_or_dir in readdir(srcdir)
        cp(joinpath(srcdir, file_or_dir), joinpath(dstdir, file_or_dir))
    end
end

runzshinter(cmd::Cmd) = runzsh(join(cmd.exec, " "))
runzshinter(cmdstr::String) = run(`zsh -ic "$cmdstr; exit"`)

function envinfo(dstpath::AbstractString)
    mktempdir() do dir
        env = Pkg.Types.Context().env
        Pkg.Types.write_project(env.project, joinpath(dir, "Project.toml"))
        Pkg.Types.write_manifest(env.manifest, joinpath(dir, "Manifest.toml"))
        open(joinpath(dir, "versioninfo.txt"), "w") do io
            versioninfo(io)
        end
        Pkg.PlatformEngines.probe_platform_engines!()
        Pkg.PlatformEngines.package(dir, dstpath)
    end
end