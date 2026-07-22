package com.hermes.speech

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * UT-AND-POLISH-001 (REQ-FUNC-019) — request building and response parsing for the Gemini
 * `generateContent` polish call. Pure logic: no Android runtime and no network needed.
 */
class GeminiApiTest {

    @Test
    fun endpointEmbedsModel() {
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent",
            GeminiApi.endpointUrl("gemini-flash-lite-latest")
        )
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent",
            GeminiApi.endpointUrl("gemini-3.6-flash")
        )
    }

    @Test
    fun requestCarriesTextVerbatimWithDeterministicConfig() {
        val text = "he said \"hello\" and\nleft the room"
        val body = JSONObject(GeminiApi.buildRequestBody(text))

        val sys = body.getJSONObject("system_instruction")
            .getJSONArray("parts").getJSONObject(0).getString("text")
        assertTrue(sys.isNotBlank())

        // Few-shot user/model pairs first, then the real transcript as the trailing user turn.
        val contents = body.getJSONArray("contents")
        assertTrue(contents.length() >= 3)
        assertEquals(1, contents.length() % 2)
        for (i in 0 until contents.length()) {
            val expectedRole = if (i % 2 == 0) "user" else "model"
            assertEquals(expectedRole, contents.getJSONObject(i).getString("role"))
        }
        val last = contents.getJSONObject(contents.length() - 1)
        assertEquals(text, last.getJSONArray("parts").getJSONObject(0).getString("text"))

        val cfg = body.getJSONObject("generationConfig")
        assertEquals(0, cfg.getInt("temperature"))
        assertEquals("minimal", cfg.getJSONObject("thinkingConfig").getString("thinkingLevel"))
        assertEquals(GeminiApi.maxOutputTokens(text), cfg.getInt("maxOutputTokens"))
    }

    @Test
    fun outputTokensBounded() {
        assertEquals(64, GeminiApi.maxOutputTokens(""))                    // floor
        assertEquals(2048, GeminiApi.maxOutputTokens("a".repeat(100_000))) // ceiling
        assertTrue(GeminiApi.maxOutputTokens("a".repeat(300)) > 64)        // grows with input
        assertTrue(
            GeminiApi.maxOutputTokens("a".repeat(600)) <= GeminiApi.maxOutputTokens("a".repeat(1200))
        )
    }

    @Test
    fun parseJoinsPartsAndTrims() {
        val body = """{"candidates":[{"content":{"parts":[{"text":"Hello, "},{"text":"world. "}],"role":"model"},"finishReason":"STOP"}]}"""
        assertEquals("Hello, world.", GeminiApi.parseResponse(body, "hello world"))
    }

    @Test
    fun parseSkipsThoughtParts() {
        val body = """{"candidates":[{"content":{"parts":[{"text":"pondering...","thought":true},{"text":"Fixed."}]}}]}"""
        assertEquals("Fixed.", GeminiApi.parseResponse(body, "fixed"))
    }

    @Test
    fun parseStripsMarkdownFence() {
        val body = """{"candidates":[{"content":{"parts":[{"text":"```\nHi there.\n```"}]}}]}"""
        assertEquals("Hi there.", GeminiApi.parseResponse(body, "hi there"))
    }

    @Test
    fun parseFallsBackToOriginal() {
        val original = "raw transcript"
        // Malformed JSON (e.g. an HTML error page).
        assertEquals(original, GeminiApi.parseResponse("<html>502</html>", original))
        // No candidates at all.
        assertEquals(original, GeminiApi.parseResponse("""{"promptFeedback":{}}""", original))
        // Empty candidates array.
        assertEquals(original, GeminiApi.parseResponse("""{"candidates":[]}""", original))
        // Prompt blocked by safety.
        assertEquals(
            original,
            GeminiApi.parseResponse("""{"promptFeedback":{"blockReason":"SAFETY"},"candidates":[]}""", original)
        )
        // Candidate present but blank text.
        assertEquals(
            original,
            GeminiApi.parseResponse("""{"candidates":[{"content":{"parts":[{"text":"  "}]}}]}""", original)
        )
    }

    @Test
    fun trivialInputsAreSkipped() {
        assertTrue(GeminiApi.shouldSkipPolish(""))
        assertTrue(GeminiApi.shouldSkipPolish("yes"))
        assertTrue(GeminiApi.shouldSkipPolish("okay then"))       // fewer than 3 words
        assertTrue(GeminiApi.shouldSkipPolish("a b c"))           // 3 words but too short
        assertFalse(GeminiApi.shouldSkipPolish("please write this down now"))
        assertFalse(GeminiApi.shouldSkipPolish("me and him goes to the store yesterday and buyed milk"))
    }
}
