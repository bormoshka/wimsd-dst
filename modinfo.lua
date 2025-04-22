name = "Where's My Stuff, Dude? 2025"
description = 'Highlights nearby containers that contain necessary items.\nJust hold item, or hover over ingredients in CraftMenu\n\nCompatible to Craft Pot mod. Hover over recipe ingredients to eg. find veggies'
author = 'bormoshka'
version = '2.0.1'
forumthread = ''
api_version = 10
api_version_dst = 10 -- correct api version added
priority = -2221 -- has to be this low to load after Craft Pot mod

dst_compatible = true
all_clients_require_mod = true -- client_only_mod does not work =/
client_only_mod = false

server_filter_tags = {
    "highlighting"
}

icon_atlas = 'atlas.xml'
icon = 'icon.tex'

configuration_options = {
    {
        name = "log_level_client",
        label = "Verbose Logging for client",
        options = {
            { description = "TRACE", data = 12 },
            { description = "DEBUG", data = 7 },
            { description = "INFO", data = 3 },
            { description = "Disabled", data = 0 }
        },
        default = 0
    },
    {
        name = "log_level_server",
        label = "Verbose Logging for server",
        options = {
            { description = "TRACE", data = 12 },
            { description = "DEBUG", data = 7 },
            { description = "INFO", data = 3 },
            { description = "Disabled", data = 0 }
        },
        default = 0
    },
    {
        name = "search_radius",
        label = "Searching radius",
        hover = "The radius of searching for containers.",
        options = {
            { description = "15", data = 15 },
            { description = "30", data = 30 },
            { description = "50", data = 50 },
            { description = "80", data = 80 },
        },
        default = 30,
    },
    {
        name = "search_radius_for_tags",
        label = "Searching radius (for tags, supported by Craft Pot mod)",
        hover = "The radius of searching for containers but only for tags.",
        options = {
            { description = "10", data = 7 },
            { description = "15", data = 15 },
            { description = "20", data = 20 },
        },
        default = 15,
    },
    {
        name = "max_searched_containers",
        label = "Max containers to search",
        hover = "The max number of containers to search on the server. After that, the mod will not search for containers anymore in that search request.",
        options = {
            { description = "15", data = 15 },
            { description = "30", data = 30 },
            { description = "50", data = 50 },
            { description = "80", data = 80 },
            { description = "100", data = 100 },
            { description = "200", data = 200 },
            { description = "500", data = 500 },
        },
        default = 50,
    },
    {
        name = "highlight_multiplier",
        label = "Highlight brightness multiplier",
        hover = "That is responsible for the brightness of the highlight.",
        options = {
            { description = "10%", data = 0.1 },
            { description = "20%", data = 0.2 },
            { description = "40%", data = 0.4 },
            { description = "60%", data = 0.6 },
            { description = "80%", data = 0.8 },
            { description = "100%", data = 1.0 },
            { description = "120%", data = 1.2 },
            { description = "140%", data = 1.4 },
            { description = "160%", data = 1.6 },
            { description = "180%", data = 1.8 },
            { description = "200%", data = 2.0 },
        },
        default = 1.0,
    },
}