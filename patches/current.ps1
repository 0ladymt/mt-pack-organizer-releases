param(
    [Parameter(Mandatory=$true)][string]$SourcePath
)

$ErrorActionPreference = 'Stop'
$BaseVersion = '0.9.6'
$TargetVersion = '0.9.7'
$s = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8

function Replace-Required {
    param([string]$Old,[string]$New,[string]$Label)
    if (-not $script:s.Contains($Old)) { throw "Patch falhou em: $Label" }
    $script:s = $script:s.Replace($Old,$New)
}

Replace-Required 'Pack Organizer 0.9.6' 'Pack Organizer 0.9.7' 'título da janela'
Replace-Required 'Text="v0.9.6"' 'Text="v0.9.7"' 'badge de versão'
Replace-Required "$" + "script:AppVersion = '0.9.6'" "$" + "script:AppVersion = '0.9.7'" 'versão interna'

Replace-Required 'Name="lblPiecePath" Text="-" Foreground="#68646D" FontSize="9" TextWrapping="Wrap" Margin="0,3,0,0"' 'Name="lblPiecePath" Text="-" Visibility="Collapsed"' 'nome duplicado'
Replace-Required 'Content="⏮  INÍCIO" Height="31" FontSize="9"' 'Content="INÍCIO" Height="34" FontSize="11" FontWeight="Bold"' 'botão início'
Replace-Required 'Content="FIM  ⏭" Height="31" FontSize="9"' 'Content="FIM" Height="34" FontSize="11" FontWeight="Bold"' 'botão fim'
Replace-Required 'Name="mainContent" Visibility="Collapsed" Margin="18,8,18,0"' 'Name="mainContent" Visibility="Collapsed" Margin="18,10,18,18"' 'margem do conteúdo'
Replace-Required 'Name="btnDeleteTexture" Grid.Row="2" Content="EXCLUIR TEXTURA SELECIONADA" Height="38" Margin="0,8,0,0"' 'Name="btnDeleteTexture" Grid.Row="2" Content="EXCLUIR TEXTURA SELECIONADA" Height="40" Margin="0,10,0,8"' 'respiro do botão de textura'

Replace-Required "[pscustomobject]@{Key='feet';Display='FEET • SAPATOS'},[pscustomobject]@{Key='teef';Display='TEEF • DENTES'},[pscustomobject]@{Key='accs';Display='ACCS • ACESSÓRIOS'}," "[pscustomobject]@{Key='feet';Display='FEET • SAPATOS'},[pscustomobject]@{Key='teef';Display='TEEF • ACESSÓRIOS'},[pscustomobject]@{Key='accs';Display='ACCS • CAMISAS'}," 'categorias teef/accs'
Replace-Required "[pscustomobject]@{Key='task';Display='TASK • COLETES / EQUIP.'},[pscustomobject]@{Key='decl';Display='DECL • DECAL / SOBREPOSIÇÃO'},[pscustomobject]@{Key='jbib';Display='JBIB • BLUSAS / JAQUETAS'}," "[pscustomobject]@{Key='task';Display='TASK • COLETES'},[pscustomobject]@{Key='decl';Display='DECL • ADESIVOS'},[pscustomobject]@{Key='jbib';Display='JBIB • JAQUETAS'}," 'categorias task/decl/jbib'
Replace-Required "[pscustomobject]@{Key='p_head';Display='P_HEAD • CHAPÉUS'},[pscustomobject]@{Key='p_eyes';Display='P_EYES • ÓCULOS'},[pscustomobject]@{Key='p_ears';Display='P_EARS • ORELHAS'}," "[pscustomobject]@{Key='p_head';Display='P_HEAD • CHAPÉUS'},[pscustomobject]@{Key='p_eyes';Display='P_EYES • ÓCULOS'},[pscustomobject]@{Key='p_ears';Display='P_EARS • BRINCOS'}," 'categoria p_ears'
Replace-Required "[pscustomobject]@{Key='p_lwrist';Display='P_LWRIST • PULSO ESQ.'},[pscustomobject]@{Key='p_rwrist';Display='P_RWRIST • PULSO DIR.'}" "[pscustomobject]@{Key='p_lwrist';Display='P_LWRIST • RELÓGIOS'},[pscustomobject]@{Key='p_rwrist';Display='P_RWRIST • BRACELETES'}" 'categorias pulso'

Replace-Required '<Style TargetType="ComboBox">' '<Style TargetType="ComboBox"><Setter Property="FocusVisualStyle" Value="{x:Null}"/>' 'estilo combobox'
Replace-Required '<ToggleButton Focusable="False" Background="#01000000" BorderBrush="{x:Null}" BorderThickness="0"' '<ToggleButton Focusable="False" FocusVisualStyle="{x:Null}" OverridesDefaultStyle="True" Background="Transparent" BorderBrush="{x:Null}" BorderThickness="0"' 'toggle combobox'
Replace-Required '<ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="#01000000"/></ControlTemplate></ToggleButton.Template>' '<ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"/></ControlTemplate></ToggleButton.Template>' 'template combobox'

$newGizmo = @'
<Grid Width="142" Height="142" HorizontalAlignment="Center" VerticalAlignment="Center" Background="#01000000">
                    <Ellipse Name="gizmoRoll" Width="112" Height="112" Stroke="#9D58C7" StrokeThickness="3" Opacity="0.90" Cursor="Hand" ToolTip="Girar no eixo Z"/>
                    <Ellipse Name="gizmoYaw" Width="132" Height="36" Stroke="#A95FE0" StrokeThickness="3.5" Opacity="0.95" Cursor="Hand" ToolTip="Girar no eixo Y"/>
                    <Ellipse Name="gizmoPitch" Width="36" Height="132" Stroke="#A95FE0" StrokeThickness="3.5" Opacity="0.95" Cursor="Hand" ToolTip="Girar no eixo X"/>
                    <Ellipse Name="yawHandleL" Width="12" Height="12" Fill="#DDAEFF" Stroke="#FFFFFF" StrokeThickness="1" HorizontalAlignment="Left" VerticalAlignment="Center" Cursor="Hand"/>
                    <Ellipse Name="yawHandleR" Width="12" Height="12" Fill="#DDAEFF" Stroke="#FFFFFF" StrokeThickness="1" HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand"/>
                    <Ellipse Name="pitchHandleT" Width="12" Height="12" Fill="#DDAEFF" Stroke="#FFFFFF" StrokeThickness="1" HorizontalAlignment="Center" VerticalAlignment="Top" Cursor="Hand"/>
                    <Ellipse Name="pitchHandleB" Width="12" Height="12" Fill="#DDAEFF" Stroke="#FFFFFF" StrokeThickness="1" HorizontalAlignment="Center" VerticalAlignment="Bottom" Cursor="Hand"/>
                    <Ellipse Name="rollHandleA" Width="11" Height="11" Fill="#C989F5" Stroke="#FFFFFF" StrokeThickness="1" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,13,13,0" Cursor="Hand"/>
                    <Ellipse Name="rollHandleB" Width="11" Height="11" Fill="#C989F5" Stroke="#FFFFFF" StrokeThickness="1" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="13,0,0,13" Cursor="Hand"/>
                    <Line Name="gizmoX" X1="71" Y1="71" X2="124" Y2="71" Stroke="#B76AE8" StrokeThickness="3"/>
                    <Polygon Points="124,65 140,71 124,77" Fill="#DDAEFF"/>
                    <Line Name="gizmoZ" X1="71" Y1="71" X2="71" Y2="18" Stroke="#B76AE8" StrokeThickness="3"/>
                    <Polygon Points="65,18 71,2 77,18" Fill="#DDAEFF"/>
                    <Ellipse Width="14" Height="14" Fill="#E3BEFF" Stroke="#FFFFFF" StrokeThickness="1" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
'@
$gizmoPattern = '(?s)<Grid Width="118" Height="118"[^>]*>\s*<Ellipse Name="gizmoRoll".*?</Grid>'
$changed = [regex]::Replace($s,$gizmoPattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newGizmo },1)
if($changed -eq $s){ throw 'Patch falhou em: gizmo' }
$s=$changed
Replace-Required "'gizmoYaw','gizmoPitch','gizmoRoll','gizmoX','gizmoZ'" "'gizmoYaw','gizmoPitch','gizmoRoll','yawHandleL','yawHandleR','pitchHandleT','pitchHandleB','rollHandleA','rollHandleB','gizmoX','gizmoZ'" 'nomes do gizmo'

$endpointCode = @'
foreach($g in @($yawHandleL,$yawHandleR)) { $g.Add_MouseLeftButtonDown({param($s,$e) Start-TransformDrag 'ROTATE_YAW' $e}) }
foreach($g in @($pitchHandleT,$pitchHandleB)) { $g.Add_MouseLeftButtonDown({param($s,$e) Start-TransformDrag 'ROTATE_PITCH' $e}) }
foreach($g in @($rollHandleA,$rollHandleB)) { $g.Add_MouseLeftButtonDown({param($s,$e) Start-TransformDrag 'ROTATE_ROLL' $e}) }
foreach($g in @($yawHandleL,$yawHandleR,$pitchHandleT,$pitchHandleB,$rollHandleA,$rollHandleB)) {
    $g.Add_MouseEnter({param($s,$e); $s.Fill=New-SolidBrush '#F0D6FF'; $s.Width=15; $s.Height=15})
    $g.Add_MouseLeave({param($s,$e); $s.Fill=New-SolidBrush '#DDAEFF'; $s.Width=12; $s.Height=12})
}

'@
$dialogPattern = '(?m)^.*\$win\.ShowDialog\(\).*$'
$changed = [regex]::Replace($s,$dialogPattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $endpointCode + $m.Value },1)
if($changed -eq $s){
    Write-Host 'DIAGNÓSTICO ShowDialog:'
    $s -split "[\r\n]+" | Where-Object { $_ -match 'ShowDialog|gizmoYaw|viewHost' } | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    throw 'Patch falhou em: ShowDialog'
}
$s=$changed

$pattern = '(?s)function Start-ThumbnailQueue \{.*?\r?\n\}\r?\n\r?\nfunction Populate-Textures'
$newQueue = @'
function Start-ThumbnailQueue {
    param([object[]]$Items)
    $script:ThumbGeneration = [int]$script:ThumbGeneration + 1
    $generation = $script:ThumbGeneration
    $queue = @($Items | Where-Object { $_ -and $_.Tag })
    if($queue.Count -eq 0){ return }

    foreach($it in $queue) {
        $localItem = $it
        $localGeneration = $generation
        $action = [Action]{
            try {
                if($script:ThumbGeneration -eq $localGeneration -and $localItem){
                    Load-ThumbnailForItem $localItem
                }
            } catch { Write-AppLog ('Thumbnail dispatcher: '+$_.Exception.Message) }
        }.GetNewClosure()
        $null = $win.Dispatcher.BeginInvoke($action,[Windows.Threading.DispatcherPriority]::Background)
    }
}

function Populate-Textures
'@
$changed = [regex]::Replace($s,$pattern,$newQueue,1)
if($changed -eq $s){ throw 'Patch falhou em: fila de miniaturas' }
$s=$changed

$nl=[Environment]::NewLine
Replace-Required '$script:PopulatingTextures = $false' ('$script:PopulatingTextures = $false'+$nl+'$script:ThumbGeneration = 0') 'contador de miniaturas'
Replace-Required 'if ($lstTextures.SelectedItem) { Apply-TextureItem $lstTextures.SelectedItem }' 'if ($lstTextures.SelectedItem) { Apply-TextureItem $lstTextures.SelectedItem; Load-ThumbnailForItem $lstTextures.SelectedItem }' 'primeira miniatura'

Replace-Required 'Clique na peça para selecionar • anéis roxos = rotação por eixo • cantos = escala • Shift = encaixe 5°' 'Clique na peça • controles lilás = rotação por eixo • cantos = escala • Shift = encaixe 5°' 'texto do viewer'
Replace-Required '<Image Name="imgBrandLogo" Width="150" Height="67"' '<Image Name="imgBrandLogo" Width="166" Height="72"' 'logo no header'
Replace-Required '<Border Grid.Column="0" Background="#101014" CornerRadius="14" BorderBrush="#29252F"' '<Border Grid.Column="0" Background="#0E0E12" CornerRadius="14" BorderBrush="#302A36"' 'painel esquerdo'
Replace-Required '<Border Grid.Column="4" Background="#111114" CornerRadius="13" BorderBrush="#2D2931"' '<Border Grid.Column="4" Background="#0E0E12" CornerRadius="13" BorderBrush="#302A36"' 'painel direito'

Set-Content -LiteralPath $SourcePath -Value $s -Encoding UTF8
Write-Host "Patch $TargetVersion aplicado com sucesso."

$changed = [regex]::Replace($s,$dialogPattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $endpointCode + $m.Value },1)
if($changed -eq $s){
    Write-Host 'DIAGNÓSTICO ShowDialog:'
    $s -split "[\r\n]+" | Where-Object { $_ -match 'ShowDialog|gizmoYaw|viewHost' } | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    throw 'Patch falhou em: ShowDialog'
}
$s=$changed

$pattern = '(?s)function Start-ThumbnailQueue \{.*?\r?\n\}\r?\n\r?\nfunction Populate-Textures'
$newQueue = @'
function Start-ThumbnailQueue {
    param([object[]]$Items)
    $script:ThumbGeneration = [int]$script:ThumbGeneration + 1
    $generation = $script:ThumbGeneration
    $queue = @($Items | Where-Object { $_ -and $_.Tag })
    if($queue.Count -eq 0){ return }

    foreach($it in $queue) {
        $localItem = $it
        $localGeneration = $generation
        $action = [Action]{
            try {
                if($script:ThumbGeneration -eq $localGeneration -and $localItem){
                    Load-ThumbnailForItem $localItem
                }
            } catch { Write-AppLog ('Thumbnail dispatcher: '+$_.Exception.Message) }
        }.GetNewClosure()
        $null = $win.Dispatcher.BeginInvoke($action,[Windows.Threading.DispatcherPriority]::Background)
    }
}

function Populate-Textures
'@
$changed = [regex]::Replace($s,$pattern,$newQueue,1)
if($changed -eq $s){ throw 'Patch falhou em: fila de miniaturas' }
$s=$changed

$nl=[Environment]::NewLine
Replace-Required '$script:PopulatingTextures = $false' ('$script:PopulatingTextures = $false'+$nl+'$script:ThumbGeneration = 0') 'contador de miniaturas'
Replace-Required 'if ($lstTextures.SelectedItem) { Apply-TextureItem $lstTextures.SelectedItem }' 'if ($lstTextures.SelectedItem) { Apply-TextureItem $lstTextures.SelectedItem; Load-ThumbnailForItem $lstTextures.SelectedItem }' 'primeira miniatura'

Replace-Required 'Clique na peça para selecionar • anéis roxos = rotação por eixo • cantos = escala • Shift = encaixe 5°' 'Clique na peça • controles lilás = rotação por eixo • cantos = escala • Shift = encaixe 5°' 'texto do viewer'
Replace-Required '<Image Name="imgBrandLogo" Width="150" Height="67"' '<Image Name="imgBrandLogo" Width="166" Height="72"' 'logo no header'
Replace-Required '<Border Grid.Column="0" Background="#101014" CornerRadius="14" BorderBrush="#29252F"' '<Border Grid.Column="0" Background="#0E0E12" CornerRadius="14" BorderBrush="#302A36"' 'painel esquerdo'
Replace-Required '<Border Grid.Column="4" Background="#111114" CornerRadius="13" BorderBrush="#2D2931"' '<Border Grid.Column="4" Background="#0E0E12" CornerRadius="13" BorderBrush="#302A36"' 'painel direito'

Set-Content -LiteralPath $SourcePath -Value $s -Encoding UTF8
Write-Host "Patch $TargetVersion aplicado com sucesso."
