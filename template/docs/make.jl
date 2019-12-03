using Documenter, FOOBAR

const PAGES = ["Home" => "index.md", "API" => "api.md"]

makedocs(;
    modules = [FOOBAR],
    format = Documenter.HTML(prettyurls = get(ENV, "GITHUB_ACTIONS", nothing) == "true"),
    pages = PAGES,
    sitename = "FOOBAR.jl",
    authors = "Colin Summers",
    clean = true,
    doctest = true,
    checkdocs = :exports,
    linkcheck = :true,
    linkcheck_ignore = [r"^https://github.com/Lyceum/.*/actions"],
)

deploydocs(repo = "github.com/Lyceum/FOOBAR.jl.git")
