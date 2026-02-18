-- GitHub command plugin

function info()
    return {
        bindings = {"gh", "github"},
        description = "Navigate to GitHub repositories",
        example = "gh facebook/react"
    }
end

function process(full_args)
    local args = get_args(full_args, "gh")
    if args == "" then
        args = get_args(full_args, "github")
    end
    
    if args == "" then
        return "https://github.com"
    end
    
    return "https://github.com/" .. url_encode_path(args)
end
