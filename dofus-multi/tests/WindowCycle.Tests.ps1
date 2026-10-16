. "$PSScriptRoot\..\lib\WindowCycle.ps1"

Describe "Get-NextWindowHandle" {

    It "returns null when the list is empty" {
        $result = Get-NextWindowHandle -OrderedHandles @() -CurrentHandle 999 -Direction Next
        $result | Should Be $null
    }

    It "Next from no-match (-1) goes to the first element" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 999 -Direction Next
        $result | Should Be 10
    }

    It "Prev from no-match (-1) goes to the last element" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 999 -Direction Prev
        $result | Should Be 40
    }

    It "Next from a middle element advances by one" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 20 -Direction Next
        $result | Should Be 30
    }

    It "Prev from a middle element goes back by one" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 30 -Direction Prev
        $result | Should Be 20
    }

    It "Next from the last element wraps to the first" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 40 -Direction Next
        $result | Should Be 10
    }

    It "Prev from the first element wraps to the last" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 10 -Direction Prev
        $result | Should Be 40
    }

    It "works with a single-element list (wraps to itself)" {
        $result = Get-NextWindowHandle -OrderedHandles @(10) -CurrentHandle 10 -Direction Next
        $result | Should Be 10
    }
}
