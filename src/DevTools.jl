module DevTools

import Registrator, JuliaFormatter, RegistryTools
using PkgTemplates, LibGit2, Pkg, SnoopCompile, Base64
using Base: UUID
import GitHub

export register,
    LYCEUM_PKGTEMPLATE,
    pushrepo,
    namedgenerate,
    incrementversion!,
    pkgdir,
    parsetomls,
    cpinto,
    snooppkg,
    with_sandbox_env,
    register

include("git.jl")
include("misc.jl")
include("packaging.jl")
include("Compat.jl")

end # module
