package com.safeguard.app.engine

import com.safeguard.app.engine.domain.DomainName
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DomainNameTest {
    @Test
    fun normalizesQueryNames() {
        assertEquals("example.com", DomainName.normalizeQueryName("Example.COM."))
        assertEquals("_dmarc.example.com", DomainName.normalizeQueryName("_dmarc.example.com"))
        assertEquals("localhost", DomainName.normalizeQueryName("localhost"))
    }

    @Test
    fun rejectsMalformedQueryNames() {
        val bad = listOf(
            "", ".", "a..b", "-a.com", "a-.com", "a b.com", "exa\u0000mple.com",
            "a".repeat(64) + ".com", ("a".repeat(60) + ".").repeat(5) + "com", "ex*ample.com",
        )
        bad.forEach { assertNull(it, DomainName.normalizeQueryName(it)) }
    }

    @Test
    fun parsesUserInputIntoRuleDomains() {
        assertEquals("example.com", DomainName.parseRuleDomain("example.com"))
        assertEquals("example.com", DomainName.parseRuleDomain("  WWW.Example.com  "))
        assertEquals("example.com", DomainName.parseRuleDomain("https://www.example.com/path?q=1#x"))
        assertEquals("example.com", DomainName.parseRuleDomain("http://user@example.com:8080/"))
        assertEquals("sub.example.co.uk", DomainName.parseRuleDomain("sub.example.co.uk."))
        // Internationalised names become punycode.
        assertEquals("xn--mgbh0fb.xn--kgbechtv", DomainName.parseRuleDomain("مثال.إختبار"))
    }

    @Test
    fun rejectsInvalidRuleInput() {
        val bad = listOf(
            "", "com", "localhost", "192.168.1.1", "[::1]", "http://[::1]/",
            "exa mple.com", "example..com", "-bad.com", "example.123", "a;drop table rules;--.com",
            "%00.com", "*.example.com",
        )
        bad.forEach { assertNull(it, DomainName.parseRuleDomain(it)) }
    }

    @Test
    fun matchCandidatesWalkUpToTwoLabels() {
        assertEquals(
            listOf("a.b.example.com", "b.example.com", "example.com"),
            DomainName.matchCandidates("a.b.example.com"),
        )
        assertEquals(listOf("example.com"), DomainName.matchCandidates("example.com"))
        assertEquals(listOf("localhost"), DomainName.matchCandidates("localhost"))
    }

    @Test
    fun subdomainCheckIsLabelBased() {
        assertTrue(DomainName.isSameOrSubdomain("www.example.com", "example.com"))
        assertTrue(DomainName.isSameOrSubdomain("example.com", "example.com"))
        assertFalse(DomainName.isSameOrSubdomain("safe-example.com", "example.com"))
        assertFalse(DomainName.isSameOrSubdomain("notexample.com", "example.com"))
        assertFalse(DomainName.isSameOrSubdomain("example.com.evil.net", "example.com"))
    }
}
