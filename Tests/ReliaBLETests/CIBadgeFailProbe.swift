//
//  CIBadgeFailProbe.swift
//  ReliaBLETests
//
//  TEMPORARY: intentionally-failing test used to verify that CI (and the CI
//  status badge) correctly report a FAILING state. This file is reverted
//  before the PR is finalized — the final state of the PR must be green.
//

import Testing

@Test("CI badge fail-case probe (intentional failure — will be reverted)")
func ciBadgeFailProbe() {
    #expect(Bool(false), "Intentional failure to exercise the CI failure path.")
}
