<#
  hospedar.ps1 - hospeda o mundo compartilhado e salva no Git periodicamente.
  Uso normal: dois cliques em hospedar.bat

  Parametros opcionais:
    -IntervaloSaveMin 10     de quantos em quantos minutos envia o mundo
    -MemoriaMax 4G           RAM maxima do servidor
    -ForcarCadeado           hospeda mesmo que o cadeado seja de outra pessoa (CUIDADO)
    -ApenasSincronizar       so envia saves pendentes e libera o cadeado, sem abrir o servidor
#>
param(
    [double]$IntervaloSaveMin = 10,
    [string]$MemoriaMax = '4G',
    [switch]$ForcarCadeado,
    [switch]$ApenasSincronizar
)

# ======================= CONFIG =======================
$VersaoMinecraft = '26.3'   # troque aqui para atualizar o servidor de todo mundo
$Branch          = 'main'
$CadeadoVelhoMin = 30       # sem sinal ha mais que isso = host provavelmente caiu
$ArquivoCadeado  = 'host.lock'
$ArquivoComandos = '.comandos.txt'
# ======================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
Set-Location -LiteralPath $PSScriptRoot
[Environment]::CurrentDirectory = $PSScriptRoot   # para os metodos .NET usarem a mesma pasta
$Utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $Utf8
$Interativo = -not [Console]::IsInputRedirected

function Info($m)  { Write-Host "[hospedar] $m" -ForegroundColor Cyan }
function Aviso($m) { Write-Host "[hospedar] $m" -ForegroundColor Yellow }
function Erro($m)  { Write-Host "[hospedar] $m" -ForegroundColor Red }

# ---------------- git helpers ----------------
function GitExec([string[]]$a) {
    $out = & git @a 2>&1 | ForEach-Object { "$_" }
    $script:GitCode  = $LASTEXITCODE
    $script:GitSaida = ($out -join "`n")
    return ($script:GitCode -eq 0)
}
function GitOk { return (GitExec $args) }
function GitX {
    if (-not (GitExec $args)) { throw "git $($args -join ' ') falhou:`n$script:GitSaida" }
    return $script:GitSaida
}
function Commitar([string]$msg) {
    if (GitExec @('diff', '--cached', '--quiet')) { return $false }   # nada para commitar
    $f = Join-Path $env:TEMP 'hospedar-msg.txt'
    [IO.File]::WriteAllText($f, $msg, $Utf8)
    GitX commit -q -F $f | Out-Null
    return $true
}
function Push { return (GitExec @('push', '-q', 'origin', "HEAD:$Branch")) }

# ---------------- cadeado ----------------
function Ler-Cadeado([string]$texto) {
    if (-not $texto) { return $null }
    $h = @{}
    foreach ($l in ($texto -split "`r?`n")) { if ($l -match '^([\w-]+)=(.*)$') { $h[$matches[1]] = $matches[2] } }
    if (-not $h['id']) { return $null }
    return $h
}
function Cadeado-Remoto {
    if (GitExec @('show', "origin/${Branch}:$ArquivoCadeado")) { return (Ler-Cadeado $script:GitSaida) }
    return $null
}
function Cadeado-Local {
    $p = Join-Path $PSScriptRoot $ArquivoCadeado
    if (Test-Path -LiteralPath $p) { return (Ler-Cadeado ([IO.File]::ReadAllText($p))) }
    return $null
}
function Escrever-Cadeado {
    $agora = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $txt = "id=$MeuId`nhost=$Nome`nmaquina=$env:COMPUTERNAME`ndesde=$script:Desde`nultimo-sinal=$agora`n"
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot $ArquivoCadeado), $txt, $Utf8)
}
function Minutos-Desde([string]$iso) {
    try { return [int]((Get-Date) - [DateTimeOffset]::Parse($iso).LocalDateTime).TotalMinutes } catch { return 99999 }
}

# ---------------- server.jar ----------------
function Garantir-ServerJar {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $man = Invoke-RestMethod 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
        $v = $man.versions | Where-Object { $_.id -eq $VersaoMinecraft } | Select-Object -First 1
        if (-not $v) { throw "versao $VersaoMinecraft nao existe" }
        $srv = (Invoke-RestMethod $v.url).downloads.server
    } catch {
        if (Test-Path server.jar) { Aviso "Nao consegui checar a versao do server.jar ($_). Usando o que ja existe."; return }
        throw "Nao consegui baixar o server.jar: $_"
    }
    if ((Test-Path server.jar) -and (Get-FileHash server.jar -Algorithm SHA1).Hash -eq $srv.sha1) { return }
    Info "Baixando server.jar $VersaoMinecraft..."
    Invoke-WebRequest $srv.url -OutFile server.jar.tmp -UseBasicParsing
    if ((Get-FileHash server.jar.tmp -Algorithm SHA1).Hash -ne $srv.sha1) { Remove-Item server.jar.tmp; throw 'Download do server.jar corrompido.' }
    Move-Item -Force server.jar.tmp server.jar
}

# ---------------- sincronizacao inicial ----------------
function Sincronizar {
    Info 'Baixando a versao mais recente do mundo...'
    if (-not (GitOk fetch -q origin)) { throw "Sem acesso ao repositorio (internet? permissao?):`n$script:GitSaida" }
    if (-not (GitOk rev-parse -q --verify "origin/$Branch")) { throw "O repositorio remoto nao tem a branch '$Branch'. Veja o README (primeira publicacao)." }

    $sujo  = [bool](GitX status --porcelain)
    $ahead = [int](GitX rev-list --count "origin/$Branch..HEAD")
    if (-not $sujo -and $ahead -eq 0) { GitX reset -q --hard "origin/$Branch" | Out-Null; return }

    $cadR = Cadeado-Remoto
    $cadeadoMeuOuLivre = (-not $cadR) -or ($cadR['id'] -eq $MeuId)
    $remotoEhAncestral = GitOk merge-base --is-ancestor "origin/$Branch" HEAD
    if ($cadeadoMeuOuLivre -and $remotoEhAncestral) {
        Aviso 'Achei saves locais que nao foram enviados (a ultima sessao terminou mal). Enviando agora...'
        if ($sujo) { GitX add -A | Out-Null; Commitar "[recuperacao] $Nome - saves locais pendentes" | Out-Null }
        if (-not (Push)) { throw "Falha ao enviar os saves pendentes:`n$script:GitSaida" }
        Info 'Saves pendentes enviados.'
    } else {
        $mundoMudou = ($ahead -gt 0) -or [bool](GitX status --porcelain -- world)
        if ($mundoMudou -and (Test-Path world)) {
            $dest = Join-Path 'backups-locais' ('world-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Aviso "Seu mundo local diverge do repositorio (outra pessoa jogou depois)."
            Aviso "Guardando uma copia em $dest e usando a versao oficial."
            New-Item -ItemType Directory -Force $dest | Out-Null
            Copy-Item -Recurse world $dest
        }
        GitX reset -q --hard "origin/$Branch" | Out-Null
        GitX clean -q -fd -- world | Out-Null
    }
}

# ---------------- comunicacao com o servidor ----------------
function Enviar([string]$cmd) {
    if ($script:Proc -and -not $script:Proc.HasExited) { try { $script:Stdin.WriteLine($cmd) } catch {} }
}
function Pump {
    foreach ($k in @('out', 'err')) {
        while ($script:T[$k] -and $script:T[$k].IsCompleted) {
            $l = $script:T[$k].Result
            if ($null -eq $l) { $script:T[$k] = $null; break }
            Write-Host $l
            if ($l -match 'Done \(') { $script:Pronto = $true }
            if ($l -match 'Saved the game') { $script:Salvou = $true }
            $script:T[$k] = $script:R[$k].ReadLineAsync()
        }
    }
    if ($Interativo) {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') {
                Write-Host ''; Aviso 'Ctrl+C: parando o servidor com seguranca...'; Enviar 'stop'
            } elseif ($key.Key -eq 'Enter') {
                Write-Host ''; Enviar $script:Buf; $script:Buf = ''
            } elseif ($key.Key -eq 'Backspace') {
                if ($script:Buf.Length -gt 0) { $script:Buf = $script:Buf.Substring(0, $script:Buf.Length - 1); Write-Host "`b `b" -NoNewline }
            } elseif ($key.KeyChar -ne [char]0) {
                $script:Buf += $key.KeyChar; Write-Host $key.KeyChar -NoNewline
            }
        }
    }
    # comandos externos: qualquer linha escrita em .comandos.txt vai para o console do servidor
    if ((Test-Path -LiteralPath $ArquivoComandos) -and ((Get-Date) -ge $script:ProxChecagemCmd)) {
        $script:ProxChecagemCmd = (Get-Date).AddMilliseconds(500)
        try {
            $linhas = [IO.File]::ReadAllLines($ArquivoComandos, $Utf8)
            Remove-Item -LiteralPath $ArquivoComandos -ErrorAction Stop
            foreach ($l in $linhas) { if ($l.Trim()) { Info "> $l"; Enviar $l } }
        } catch {}
    }
    if ($script:PushProc -and $script:PushProc.HasExited) {
        $code = $script:PushProc.ExitCode; $script:PushProc = $null
        if ($code -eq 0) { Info "Mundo enviado ($(Get-Date -Format 'HH:mm'))." } else { Push-Falhou }
    }
}
function Esperar([scriptblock]$cond, [int]$seg) {
    $lim = (Get-Date).AddSeconds($seg)
    while (-not (& $cond) -and (Get-Date) -lt $lim) { Pump; Start-Sleep -Milliseconds 50 }
    return [bool](& $cond)
}
function Push-Falhou {
    if (GitOk fetch -q origin) {
        $cadR = Cadeado-Remoto
        if (-not $cadR -or $cadR['id'] -ne $MeuId) {
            $script:PerdeuCadeado = $true
            Erro '=============================================================='
            Erro " ATENCAO: o cadeado agora e de '$($cadR['host'])' (quebrado a forca)."
            Erro ' Seus saves NAO estao mais sendo enviados. Pare o servidor (stop)'
            Erro ' e combine com o pessoal qual mundo fica.'
            Erro '=============================================================='
            return
        }
    }
    Aviso 'Falha ao enviar o mundo (internet?). Tento de novo no proximo save.'
}
function Iniciar-Push {
    if ($script:PerdeuCadeado -or $script:PushProc) { return }
    $script:PushProc = Start-Process git -ArgumentList @('push', '-q', 'origin', "HEAD:$Branch") -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $env:TEMP 'hospedar-push.out') -RedirectStandardError (Join-Path $env:TEMP 'hospedar-push.err')
    $null = $script:PushProc.Handle   # sem isso o ExitCode vem vazio (bug do Start-Process)
}
function Salvar-Periodico {
    if ($script:PerdeuCadeado) { return }
    $script:Salvou = $false
    Enviar 'save-off'
    Enviar 'save-all flush'
    try {
        Esperar { $script:Salvou -or $script:Proc.HasExited } 120 | Out-Null
        if (-not $script:Salvou) {
            if (-not $script:Proc.HasExited) { Aviso 'O servidor nao confirmou o save; pulo este envio.' }
            return
        }
        Escrever-Cadeado
        GitX add -A | Out-Null
        Commitar "[save] $Nome - $(Get-Date -Format 'dd/MM HH:mm')" | Out-Null
    } catch { Aviso "Erro ao commitar o save: $_" }
    finally { Enviar 'save-on' }
    Iniciar-Push
}

# ======================= INICIO =======================
if (-not (Get-Command git -ErrorAction SilentlyContinue))  { Erro 'Git nao encontrado. Instale: https://git-scm.com/download/win'; exit 1 }
if (-not (Get-Command java -ErrorAction SilentlyContinue)) { Erro 'Java nao encontrado. Instale o Java 25 (Temurin ou Oracle).'; exit 1 }
if (-not (GitOk remote get-url origin)) { Erro 'Esta pasta nao tem o remoto "origin". Clone o repositorio em vez de copiar a pasta.'; exit 1 }

$Nome = (& git config user.name)
if (-not $Nome) {
    $Nome = Read-Host 'Seu nome (aparece no historico de saves)'
    & git config user.name $Nome
}
if (-not (& git config user.email)) { & git config user.email (($Nome -replace '\s', '') + '@mundo.local') }
$MeuId = "$Nome@$env:COMPUTERNAME"

try { Sincronizar } catch { Erro $_; exit 1 }

if ($ApenasSincronizar) {
    $cad = Cadeado-Local
    if ($cad -and $cad['id'] -eq $MeuId) {
        Remove-Item -LiteralPath $ArquivoCadeado
        GitX add -A | Out-Null
        Commitar "[fim] $Nome liberou o cadeado" | Out-Null
        if (Push) { Info 'Cadeado liberado.' } else { Erro "Falha ao enviar: $script:GitSaida"; exit 1 }
    }
    Info 'Tudo sincronizado.'; exit 0
}

# ---- pega o cadeado ----
$cad = Cadeado-Local
if ($cad -and $cad['id'] -ne $MeuId) {
    $idade = Minutos-Desde $cad['ultimo-sinal']
    if (-not $ForcarCadeado) {
        if ($idade -lt $CadeadoVelhoMin) {
            Erro "$($cad['host']) ja esta hospedando (desde $($cad['desde']), ultimo save ha $idade min)."
            Erro 'Entre pelo IP do Radmin dessa pessoa em vez de hospedar.'
            exit 2
        }
        Aviso "O cadeado e de $($cad['host']), mas o ultimo sinal foi ha $idade min - o PC dessa pessoa deve ter caido."
        Aviso "Se voce hospedar, o que $($cad['host']) jogou depois do ultimo save sera perdido."
        if (-not $Interativo) { exit 2 }
        if ((Read-Host 'Quebrar o cadeado e hospedar? (s/N)') -notmatch '^[sS]') { exit 2 }
    }
    Aviso "Quebrando o cadeado de $($cad['host'])."
}
try { Garantir-ServerJar } catch { Erro $_; exit 1 }
$script:Desde = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
Escrever-Cadeado
GitX add -A | Out-Null
Commitar "[inicio] $Nome comecou a hospedar" | Out-Null
if (-not (Push)) {
    $saidaPush = $script:GitSaida
    GitOk fetch -q origin | Out-Null
    GitOk reset -q --hard "origin/$Branch" | Out-Null
    $c = Cadeado-Local
    if ($c) { Erro "Nao consegui pegar o cadeado - $($c['host']) pegou antes de voce." }
    else { Erro "Nao consegui pegar o cadeado:`n$saidaPush" }
    exit 2
}
Info "Cadeado e seu. Saves automaticos a cada $IntervaloSaveMin min."

# ---- roda o servidor ----
$script:Proc = $null; $script:PushProc = $null; $script:PerdeuCadeado = $false
$script:Pronto = $false; $script:Salvou = $false; $script:Buf = ''; $script:ProxChecagemCmd = Get-Date
Remove-Item -LiteralPath $ArquivoComandos -ErrorAction SilentlyContinue
$ctrlCAntes = $false
try {
    if ($Interativo) { $ctrlCAntes = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'java'
    $psi.Arguments = "-Xmx$MemoriaMax -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 -jar server.jar nogui"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.WorkingDirectory = $PSScriptRoot
    $script:Proc  = [Diagnostics.Process]::Start($psi)
    $script:Stdin = New-Object IO.StreamWriter($script:Proc.StandardInput.BaseStream, $Utf8)
    $script:Stdin.AutoFlush = $true
    $script:R = @{ out = $script:Proc.StandardOutput; err = $script:Proc.StandardError }
    $script:T = @{ out = $script:R.out.ReadLineAsync(); err = $script:R.err.ReadLineAsync() }

    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.InterfaceAlias -like '*Radmin*' } | Select-Object -First 1).IPAddress
        $porta = (Select-String -Path server.properties -Pattern '^server-port=(\d+)').Matches[0].Groups[1].Value
        if ($ip) { Info "Seus amigos entram em: ${ip}:$porta" }
    } catch {}
    Info 'Digite comandos normalmente. Para fechar: "stop" ou Ctrl+C (NAO feche a janela no X).'

    $proximo = (Get-Date).AddMinutes($IntervaloSaveMin)
    while (-not $script:Proc.HasExited) {
        Pump
        if ($script:Pronto -and (Get-Date) -ge $proximo) { Salvar-Periodico; $proximo = (Get-Date).AddMinutes($IntervaloSaveMin) }
        Start-Sleep -Milliseconds 50
    }
}
catch { Erro "Erro: $_" }
finally {
    if ($script:Proc -and -not $script:Proc.HasExited) {
        Enviar 'stop'
        if (-not (Esperar { $script:Proc.HasExited } 120)) { Aviso 'Servidor nao parou; matando.'; $script:Proc.Kill() }
    }
    if ($script:T) { Esperar { -not $script:T.out -and -not $script:T.err } 5 | Out-Null }
    if ($Interativo) { [Console]::TreatControlCAsInput = $ctrlCAntes }
    if ($script:PushProc) { $script:PushProc.WaitForExit(); $script:PushProc = $null }

    Info 'Servidor fechado. Enviando o mundo final...'
    if ($script:PerdeuCadeado) {
        GitX add -A | Out-Null
        Commitar "[orfao] $Nome - saves depois de perder o cadeado" | Out-Null
        Erro 'Seu mundo foi salvo so localmente (o cadeado era de outra pessoa).'
        Erro 'Na proxima vez que rodar, ele vai para backups-locais\ e a versao oficial sera baixada.'
    } else {
        Remove-Item -LiteralPath $ArquivoCadeado -ErrorAction SilentlyContinue
        GitX add -A | Out-Null
        Commitar "[fim] $Nome parou de hospedar" | Out-Null
        $ok = $false
        for ($i = 1; $i -le 3 -and -not $ok; $i++) { $ok = Push; if (-not $ok) { Start-Sleep -Seconds 5 } }
        if ($ok) { Info 'Mundo enviado e cadeado liberado. Valeu!' }
        else {
            Erro "Nao consegui enviar o mundo: $script:GitSaida"
            Erro 'Quando a internet voltar, rode: hospedar.bat -ApenasSincronizar'
        }
    }
}
