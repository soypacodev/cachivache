BeforeAll {
    . (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core') 'Log.ps1')
}

Describe 'Un fallo que se repite no puede repetir el aviso' {
    <#
        Un fallo repetido dentro del bucle de WPF no debe abrir un cuadro
        de diálogo modal por cada repetición.
    #>

    BeforeEach { Reset-AvisosDeFallo }

    It 'del primero se avisa' {
        Test-DebeAvisarDelFallo -Firma 'A' | Should -BeTrue
    }

    It 'del mismo, una sola vez por muchas que vengan' {
        Test-DebeAvisarDelFallo -Firma 'A' | Should -BeTrue
        1..50 | ForEach-Object { Test-DebeAvisarDelFallo -Firma 'A' | Should -BeFalse }
    }

    It 'pero se siguen contando todas' {
        1..7 | ForEach-Object { [void](Test-DebeAvisarDelFallo -Firma 'A') }
        (Get-VecesQueFallo)['A'] | Should -Be 7 -Because (
            'a la pantalla va uno, pero el registro tiene que poder decir cuantas veces paso')
    }

    It 'de un fallo DISTINTO si se avisa' {
        Test-DebeAvisarDelFallo -Firma 'A' | Should -BeTrue
        Test-DebeAvisarDelFallo -Firma 'B' | Should -BeTrue -Because (
            'silenciar el segundo fallo por culpa del primero seria esconder informacion nueva')
    }

    It 'tres fallos distintos son el limite' {
        Test-DebeAvisarDelFallo -Firma 'A' | Should -BeTrue
        Test-DebeAvisarDelFallo -Firma 'B' | Should -BeTrue
        Test-DebeAvisarDelFallo -Firma 'C' | Should -BeTrue
        Test-DebeAvisarDelFallo -Firma 'D' | Should -BeFalse -Because (
            'tres fallos distintos ya son un programa roto; el cuarto aviso solo tapa el boton de cerrar')
    }

    It 'ante la duda, avisa' {
        # Una firma vacía es un fallo sin identificar: mejor repetir el
        # aviso que callarlo.
        foreach ($vacia in @('', '   ', $null)) {
            Test-DebeAvisarDelFallo -Firma $vacia | Should -BeTrue
        }
    }

    It 'olvidar el estado vuelve a avisar' {
        [void](Test-DebeAvisarDelFallo -Firma 'A')
        Test-DebeAvisarDelFallo -Firma 'A' | Should -BeFalse
        Reset-AvisosDeFallo
        Test-DebeAvisarDelFallo -Firma 'A' | Should -BeTrue
    }
}

Describe 'La firma distingue fallos que se parecen' {

    It 'no revienta con nulo' {
        { Get-FirmaDeFallo -Excepcion $null } | Should -Not -Throw
        Get-FirmaDeFallo -Excepcion $null | Should -Be ''
    }

    It 'dos excepciones del mismo tipo y mensaje son el mismo fallo' {
        $a = [InvalidOperationException]::new('lo mismo')
        $b = [InvalidOperationException]::new('lo mismo')
        Get-FirmaDeFallo -Excepcion $a | Should -Be (Get-FirmaDeFallo -Excepcion $b)
    }

    It 'el mismo mensaje con distinto tipo NO es el mismo fallo' {
        # Muchos fallos no relacionados comparten mensaje; el mensaje solo
        # no basta como firma.
        $a = [InvalidOperationException]::new('igual')
        $b = [ArgumentException]::new('igual')
        Get-FirmaDeFallo -Excepcion $a | Should -Not -Be (Get-FirmaDeFallo -Excepcion $b)
    }

    It 'distinto mensaje con el mismo tipo tampoco' {
        $a = [InvalidOperationException]::new('uno')
        $b = [InvalidOperationException]::new('otro')
        Get-FirmaDeFallo -Excepcion $a | Should -Not -Be (Get-FirmaDeFallo -Excepcion $b)
    }

    It 'la firma lleva el tipo y el mensaje dentro' {
        $firma = Get-FirmaDeFallo -Excepcion ([InvalidOperationException]::new('un mensaje raro'))
        $firma | Should -Match 'InvalidOperationException'
        $firma | Should -Match 'un mensaje raro'
    }
}
