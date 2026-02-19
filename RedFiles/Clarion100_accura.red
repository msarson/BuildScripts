-- Accura local redirection for Clarion 10.0
-- Managed by BuildScripts - do not edit in workspace directly
-- This file is copied over the workspace version after checkout

[Debug]
*.exe = .\buildsql
*.dll = .\buildsql
*.clw = .\genfiles\sqlsource
*.inc = .\genfiles\sqlsource
*.exp = .\genfiles\exp

[Release]
*.exe = .\buildsql
*.dll = .\buildsql
*.clw = .\genfiles\sqlsource
*.inc = .\genfiles\sqlsource
*.exp = .\genfiles\exp

-- clarion works through the red top to bottom, so including default red at end
{include %bin%\%REDNAME%}
