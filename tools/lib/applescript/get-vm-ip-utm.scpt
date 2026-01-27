#!/usr/bin/osascript

on run argv
    -- Validate arguments
    if (count of argv) is less than 1 then
        return "Error: You must provide the VM name as an argument"
    end if

    set vmName to item 1 of argv

    tell application "UTM"
        try
            -- Find the virtual machine by name
            set targetVM to first virtual machine whose name is vmName

            -- Check if VM is running
            if status of targetVM is not started then
                return ""
            end if

            -- Query IP addresses from the running VM (returns list of text)
            set ipAddresses to query ip of targetVM

            -- Return the first IP address (IPv4 is returned before IPv6 if available)
            if (count of ipAddresses) > 0 then
                return item 1 of ipAddresses
            else
                return ""
            end if

        on error errMsg
            -- VM not found or other error
            return ""
        end try
    end tell
end run
