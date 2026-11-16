function Test-ScopedEnvironment {
    $absent = 'FIXTURE_SCOPE_ABSENT'
    $existing = 'FIXTURE_SCOPE_EXISTING'
    $empty = 'FIXTURE_SCOPE_EMPTY'
    $ambient = 'CARGO_RUSTBXL_SCOPE_TEST'
    $names = @($absent, $existing, $empty, $ambient)
    $original = @{}
    foreach ($name in $names) { $original[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        [Environment]::SetEnvironmentVariable($absent, [NullString]::Value)
        [Environment]::SetEnvironmentVariable($existing, 'before')
        [Environment]::SetEnvironmentVariable($empty, '')
        [Environment]::SetEnvironmentVariable($ambient, 'ambient')
        $emptyValue = [Environment]::GetEnvironmentVariable($empty)
        Invoke-WithEnvironment @{$absent='outer'; $existing='outer'; $empty='outer'} {
            Assert ($env:FIXTURE_SCOPE_ABSENT -ceq 'outer') 'Missing variable was not set.'
            Assert ($null -eq [Environment]::GetEnvironmentVariable($ambient)) 'Ambient Cargo override was not removed.'
            Invoke-WithEnvironment @{$absent='inner'; $existing=$null; $empty='inner'} {
                Assert ($env:FIXTURE_SCOPE_ABSENT -ceq 'inner') 'Nested override was not set.'
                Assert ($null -eq [Environment]::GetEnvironmentVariable($existing)) 'Explicit null did not remove the variable.'
            }
            Assert ($env:FIXTURE_SCOPE_ABSENT -ceq 'outer' -and $env:FIXTURE_SCOPE_EXISTING -ceq 'outer') 'Nested scope did not restore its caller.'
            Assert ($null -eq [Environment]::GetEnvironmentVariable($ambient)) 'Nested scope restored an ambient Cargo override too early.'
        }
        Assert ($null -eq [Environment]::GetEnvironmentVariable($absent)) 'Scope leaked a formerly absent variable.'
        Assert ($env:FIXTURE_SCOPE_EXISTING -ceq 'before') 'Scope did not restore the original value.'
        Assert ([Environment]::GetEnvironmentVariable($empty) -ceq $emptyValue) 'Scope changed the original empty state.'
        Assert ($env:CARGO_RUSTBXL_SCOPE_TEST -ceq 'ambient') 'Scope did not restore the ambient Cargo override.'
        $caught = $false
        try {
            Invoke-WithEnvironment @{$absent='exception'; $existing='exception'; $empty='exception'} {
                throw [InvalidOperationException]::new('Expected environment-scope failure.')
            }
        } catch [InvalidOperationException] {
            Assert ($_.Exception.Message -ceq 'Expected environment-scope failure.') 'Unexpected environment-scope exception.'
            $caught = $true
        }
        Assert $caught 'Environment scope swallowed the exception.'
        Assert ($null -eq [Environment]::GetEnvironmentVariable($absent)) 'Exception leaked a formerly absent variable.'
        Assert ($env:FIXTURE_SCOPE_EXISTING -ceq 'before') 'Exception did not restore the original value.'
        Assert ([Environment]::GetEnvironmentVariable($empty) -ceq $emptyValue) 'Exception changed the original empty state.'
        Assert ($env:CARGO_RUSTBXL_SCOPE_TEST -ceq 'ambient') 'Exception did not restore the ambient Cargo override.'
        return @{ absent=$true; existing=$true; emptyValuePresent=($null -ne $emptyValue); nested=$true; exception=$true; cargoOverride=$true }
    } finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, ($original[$name] ?? [NullString]::Value))
        }
    }
}
