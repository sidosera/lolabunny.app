-- YouTube command plugin

function info()
    return {
        bindings = {"yt", "youtube"},
        description = "Navigate to YouTube or search videos",
        example = "yt rust tutorial"
    }
end

function process(full_args)
    local args = get_args(full_args, "yt")
    if args == "" then
        args = get_args(full_args, "youtube")
    end
    
    if args == "" then
        return "https://youtube.com"
    end
    
    if args == "studio" then
        return "https://studio.youtube.com"
    end
    
    if args == "subs" or args == "subscriptions" then
        return "https://youtube.com/feed/subscriptions"
    end
    
    return "https://youtube.com/results?search_query=" .. url_encode(args)
end
