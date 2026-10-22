
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Fonctions seules : trouver une console existante ne crée jamais sa configuration.
function Resolve-AtelierConsoleInstallation {
    param([string]$InstallPath)
    if ($InstallPath) {
        $full=[IO.Path]::GetFullPath($InstallPath)
        if (-not (Test-Path -LiteralPath (Join-Path $full 'data-runtime.json') -PathType Leaf)) {
            throw ('Configuration data-runtime.json absente dans le dossier indiqué : ' + $full + '. Aucun fichier modifié.')
        }
        return $full
    }
    $task=Get-ScheduledTask -TaskName 'AtelierPXE-Console' -ErrorAction SilentlyContinue
    if (-not $task -or @($task.Actions).Count -ne 1) {
        throw ('La tâche AtelierPXE-Console est absente ou ambiguë sur ' + $env:COMPUTERNAME + '. Exécuter la mise à jour sur DEPLOY-01 (192.168.99.250), ou fournir -InstallPath avec le dossier de la console. Aucun fichier modifié.')
    }
    $action=$task.Actions[0]
    $candidates=New-Object 'Collections.Generic.List[string]'
    if ($action.WorkingDirectory) { $candidates.Add([Environment]::ExpandEnvironmentVariables($action.WorkingDirectory)) }
    $arguments=[string]$action.Arguments
    $match=[regex]::Match($arguments,'(?:^|\s)"(?<script>[^"]+[\\/]scripts[\\/]serve\.py)"(?:\s|$)')
    if (-not $match.Success) { $match=[regex]::Match($arguments,'(?:^|\s)(?<script>[^\s"]+[\\/]scripts[\\/]serve\.py)(?:\s|$)') }
    if ($match.Success) { $candidates.Add((Split-Path (Split-Path $match.Groups['script'].Value -Parent) -Parent)) }
    if ($action.Execute) {
        $runtime=[Environment]::ExpandEnvironmentVariables(([string]$action.Execute).Trim('"'))
        $parent=Split-Path $runtime -Parent
        if ((Split-Path $parent -Leaf) -eq 'Scripts' -and (Split-Path (Split-Path $parent -Parent) -Leaf) -eq '.venv') {
            $candidates.Add((Split-Path (Split-Path $parent -Parent) -Parent))
        }
    }
    $valid=@($candidates | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'data-runtime.json') -PathType Leaf })
    if ($valid.Count -ne 1) {
        throw ('La tâche AtelierPXE-Console existe, mais son dossier avec data-runtime.json est absent ou ambigu. Dossiers examines : ' + ($candidates -join ', ') + '. Ne pas recréer la configuration ; vérifier son emplacement ou sa sauvegarde. Aucun fichier modifié.')
    }
    return [IO.Path]::GetFullPath($valid[0])
}
