-- Jira command plugin
-- Configure JIRA_BASE to your instance

local JIRA_BASE = "https://mycompany.atlassian.net"

function info()
    return {
        bindings = {"jira", "j"},
        description = "Navigate to Jira issues or search",
        example = "jira PROJ-123"
    }
end

function process(full_args)
    local args = get_args(full_args, "jira")
    if args == "" then
        args = get_args(full_args, "j")
    end
    
    if args == "" then
        return JIRA_BASE .. "/jira/projects"
    end
    
    if string.match(args, "^%u+%-%d+$") then
        return JIRA_BASE .. "/browse/" .. args
    end
    
    return JIRA_BASE .. "/issues/?jql=text~" .. url_encode(args)
end
