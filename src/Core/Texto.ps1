<#
.SYNOPSIS
    Normalización de texto para comparar identidad.

.DESCRIPTION
    No es formato de presentación (eso es Format.ps1): reduce un texto a
    una forma canónica para decidir si dos nombres son la misma cosa. De
    ello dependen la guardia de seguridad y la detección de restos de
    programas: un cambio aquí puede hacer que la guardia deje de reconocer
    una carpeta protegida.
#>

function Remove-Tildes {
    <#
    .SYNOPSIS
        Quita los signos diacríticos de una cadena.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Transforma una cadena: no borra ningún recurso.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }

    # Atajo para ASCII imprimible (la mayoría de los casos): se evita
    # recorrer carácter a carácter en una función que se llama por cada
    # carpeta y cada token del vocabulario de programas.
    if ($Texto -cmatch '^[\x20-\x7E]*$') { return $Texto }

    $normalizado = $Texto.Normalize([Text.NormalizationForm]::FormD)
    $sb = [Text.StringBuilder]::new()
    foreach ($c in $normalizado.ToCharArray()) {
        $categoria = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($categoria -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

function ConvertTo-Token {
    <#
    .SYNOPSIS
        Reduce un texto a minúsculas sin tildes ni símbolos.
    .DESCRIPTION
        Se usa para comparar nombres de carpeta con nombres de programas
        instalados: "Adobe Acrobat (2024)" y "adobe-acrobat2024" producen
        el mismo token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Texto)

    return ((Remove-Tildes $Texto).ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Remove-SufijoVersion {
    <#
    .SYNOPSIS
        Quita los dígitos del final de un token ya normalizado.
    .DESCRIPTION
        Empareja un nombre con el mismo programa en otra versión:
        "python39" y "python", "office2016" y "office".

        Solo se quitan los dígitos finales: los iniciales forman parte del
        nombre ("7zip" no es "zip", "1password" no es "password").

        Recibe un token para que quien ya lo tiene (Test-TokenConocido) no
        normalice de nuevo; ConvertTo-TokenSinVersion parte de texto libre.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Transforma una cadena: no borra ningún recurso.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Token)

    if ([string]::IsNullOrEmpty($Token)) { return '' }
    $recortado = $Token -replace '[0-9]+$', ''

    # Un resto de menos de tres letras no sirve para emparejar.
    if ($recortado.Length -lt 3) { return $Token }
    return $recortado
}

function ConvertTo-TokenSinVersion {
    <#
    .SYNOPSIS
        Como ConvertTo-Token, pero además sin los dígitos del final.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Texto)

    return (Remove-SufijoVersion (ConvertTo-Token $Texto))
}
