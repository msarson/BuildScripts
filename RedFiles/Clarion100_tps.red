-- Accura local redirection for Clarion 10.0 (TPS mode)
-- Managed by BuildScripts - do not edit in workspace directly
-- This file is copied over the workspace version after checkout

[Debug]
*.exe = .\build
*.dll = .\build
*.clw = .\genfiles\source
*.inc = .\genfiles\source
*.exp = .\genfiles\exp

[Release]
*.exe = .\build
*.dll = .\build
*.clw = .\genfiles\source
*.inc = .\genfiles\source
*.exp = .\genfiles\exp

-- clarion works through the red top to bottom, so including default red at end
{include %bin%\%REDNAME%}
