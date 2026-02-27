# Copilot Instructions — BuildScripts

This repository contains build automation for **Accura**, a multi-module Clarion ERP application. It orchestrates two external repositories (`accuramis/accura` and `accuramis/Clarion10`) via Jenkins or interactively.

## Build Commands

All scripts run **from inside the Accura workspace directory** (e.g. `F:\jenkins-workspaces\AccuraBuild\Accura`), not from `C:\BuildScripts` itself.

### Full build (interactive / developer)
```powershell
# TPS (flat-file) mode — fetch latest branch, import apps, generate + compile
C:\BuildScripts\build.ps1 -Mode TPS -ImportApps -GenerateBuildAll

# SQL mode — same but uses SQL dictionary and templates
C:\BuildScripts\build.ps1 -Mode SQL -ImportApps -GenerateBuildAll

# Debug build (both TPS and SQL use this in CI — generates DEBUGHOOK statements)
C:\BuildScripts\build.ps1 -Mode TPS -ImportApps -GenerateBuildAll -DebugBuild
C:\BuildScripts\build.ps1 -Mode SQL -ImportApps -GenerateBuildAll -DebugBuild
```

### Sub-commands (skip git / import phases)
```powershell
# Generate CLW source only (no compile)
C:\BuildScripts\compile.ps1 -GenerateOnly

# Compile only (source already generated)
C:\BuildScripts\compile.ps1 -BuildOnly

# Generate + compile
C:\BuildScripts\compile.ps1 -GenerateBuild -Configuration Release
```

### Jenkins CI (run from within Accura workspace, git already checked out)
```powershell
C:\BuildScripts\build.ps1 -Mode TPS -ImportApps -GenerateBuildAll -SkipGitOperations -DebugBuild
C:\BuildScripts\build.ps1 -Mode SQL -ImportApps -GenerateBuildAll -SkipGitOperations -DebugBuild
```

### Diagnostic / single-app test
```powershell
# Test generate + build for the `classes` project in Release and Debug
C:\BuildScripts\test-classes-build.ps1
```

## Architecture

### Two-repo model
- `accuramis/accura` — Clarion source (`.app`, `.dct`, `.cwproj`, `.sln`, version-control APV folders)
- `accuramis/Clarion10` — Clarion IDE installation (templates, `ClarionCL.exe`, MSBuild targets)
- `C:\BuildScripts` — this repo; orchestrates both

### Build pipeline (in order)
1. **Git**: fetch + auto-switch to the most-recently-committed `v###_Build#` branch
2. **Mode switch**: copies `AccuraTPS.dct` → `accura.dct` (TPS) or `AccuraMSQL.DCT` → `Accura.DCT` (SQL)
3. **Config**: creates a fresh per-run `ClarionConfig\` in the workspace (never shared/reused — prevents ClarionCL bloat); updates `ClarionProperties.xml` with the detected Clarion version, paths, and debug/release preference
4. **Template patches**: copies any `.tpl` overrides from `C:\BuildScripts\TemplatePatches\` into Clarion installation
5. **Template registration**: registers all templates listed in `template-mapping.json` via `ClarionCL.exe /tr`; deletes `TemplateRegistry10.trf` first to force clean registration; result is cached by Clarion git SHA + TemplatePatches hash
6. **Project patches**: copies `ProjectPatches\data.cwproj` → `data.cwproj` (excludes `dataM0.CLW` — required for SQL; harmless for TPS because generation re-adds it)
7. **App import**: for each app in `accura.sln` — builds TXA from `vcDevelopment\<AppName>\` APV files via ClaInterface, then imports TXA into `.app` via `ClarionCL /ai`
8. **Generate**: runs `ClarionCL /rs <Configuration> /ag` on each `.app` to produce CLW source; copies `.Version` files from `C:\BuildScripts\VersionFiles\` into `genfiles\Version\`
9. **Compile**: MSBuild each `.cwproj` in topological dependency order (parsed from `<ProjectReference>` GUIDs in project files); failed project logs go to `build-output\failed\`

### Key external tool paths (hardcoded)
| Tool | Path |
|---|---|
| MSBuild | `C:\Windows\Microsoft.NET\Framework\v4.0.30319\msbuild.exe` |
| ClaInterface | `C:\Program Files (x86)\UpperParkSolutions\claInterface\ClaInterface.exe` |
| BuildScripts root | `C:\BuildScripts` |

## Key Conventions

### config.json
Must exist in `C:\BuildScripts\` (copy from `config.example.json`). Supports mode-specific Clarion paths:
```json
{
  "clarion10Path": "..\\Clarion",
  "clarion10Paths": { "TPS": "..\\Clarion", "SQL": "..\\Clarion" },
  "mode": "TPS"
}
```
Relative paths in `clarion10Path` are resolved from the **Accura workspace** (current working directory), not from `C:\BuildScripts`.

### Branch naming
Accura branches follow `v{version}_Build{number}` (e.g. `v640_Build7`). `build.ps1` automatically selects the branch with the most recent commit — not the highest version number.

### TPS vs SQL differences
- **TPS**: uses `AccuraTPS.dct`, TPS branch of `Clarion10` repo
- **SQL**: uses `AccuraMSQL.DCT`, same TPS branch of `Clarion10` repo (SQL Query Wizard templates `CTSQW10ABC.*` and `SQLQWADDON.TPL` are now permanently committed to the TPS branch — no separate copy step needed)
- Both TPS and SQL builds in Jenkins use `-DebugBuild`
- SQL excludes `dataM0.CLW` via project patch

### Debug vs Release generation
`-DebugBuild` controls two things:
1. **Output paths**: ClarionCL is called with `/rs Debug` which routes `.obj`, `.exe` etc. to the `[Debug]` section of `Clarion100.red`
2. **DEBUGHOOK generation**: ClarionCL reads `SharpDevelop.UseReleaseAsDefault` from `ClarionProperties.xml` to determine the active configuration before loading the `.cwproj`. Setting it to `False` makes ClarionCL treat the session as Debug, which sets `Win32App.BuildingDebug = true`, which enables `%ApplicationDebug` in templates — causing `ABFILE.TPW` to emit `DEBUGHOOK` statements in generated CLW files.

`build.ps1` automatically sets `SharpDevelop.UseReleaseAsDefault` to `False` (Debug) or `True` (Release) in the fresh workspace `ClarionConfig\ClarionProperties.xml` based on `-DebugBuild`.

**Note**: The `.cwproj` files already have `<DebugSymbols>True</DebugSymbols>` in their Debug PropertyGroup. The `SharpDevelop.UseReleaseAsDefault` setting must also be correct because ClarionCL overwrites `Win32App.BuildingDebug` from `SolutionPreferences` *before* reading the `.cwproj` — so both must align.

### Output layout (inside Accura workspace)
```
build-output\          # MSBuild logs per project
build-output\failed\   # Logs for failed projects only (attached to Jenkins failure emails)
genfiles\source\       # Generated CLW for TPS
genfiles\sqlsource\    # Generated CLW for SQL
genfiles\Version\      # .Version files copied from C:\BuildScripts\VersionFiles\
ClarionConfig\         # Fresh per-build Clarion config (auto-created, do not commit)
```

### Jenkins concurrency
A `lock('clarion-generator')` in both Jenkinsfiles prevents TPS and SQL builds from running ClarionCL simultaneously (ClarionCL is single-instance).

### ClarionProperties.xml and licensing
`ClarionProperties.xml` must be present in the `ConfigDir` used by ClarionCL. Without it, ClarionCL fails with `CLCE007: This version of Clarion is not registered`.

The file is **gitignored** because ClarionCL writes the `Serial_10` licence key back into it at runtime. It must be manually set up on each build machine with the serial number present in the `SoftVelocity.Lic` section. Use `ClarionConfig\ClarionProperties.xml.example` as a template — it contains the correct structure without the serial.

### Adding/updating project patches
Place patched `.cwproj` files in `C:\BuildScripts\ProjectPatches\`. Both `build.ps1` and `compile.ps1` apply them. Document the reason in a comment directly in the relevant script section.

### Adding template patches
Place `.tpl` overrides in `C:\BuildScripts\TemplatePatches\`. They are applied during the import phase (`-ImportApps`), before template registration. Only use this for temporary fixes — prefer committing fixes directly to the `accuramis/Clarion10` TPS branch.

