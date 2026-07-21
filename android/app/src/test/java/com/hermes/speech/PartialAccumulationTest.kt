package com.hermes.speech

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * REQ-FUNC-006 — verifies the partial-hypothesis continuation policy that keeps pre-pause speech
 * from being lost. When a partial does NOT continue the previous one, the engine commits the
 * previous chunk into the accumulated transcript. Pure logic, no Android runtime needed.
 */
class PartialAccumulationTest {

    @Test
    fun growthContinues() {
        assertTrue(AndroidSpeechEngine.partialContinues("just", "just of"))
        assertTrue(AndroidSpeechEngine.partialContinues("just of a long", "just of a long sentence"))
    }

    @Test
    fun inChunkBacktrackContinues() {
        // recognizer refines and briefly shortens within the same chunk
        assertTrue(AndroidSpeechEngine.partialContinues("just of a long", "just of a"))
    }

    @Test
    fun firstChunkFromEmptyContinues() {
        assertTrue(AndroidSpeechEngine.partialContinues("", "hello"))
    }

    @Test
    fun emptyResetIsNotContinuation() {
        // hypothesis reset to empty at a pause -> previous chunk must be committed
        assertFalse(AndroidSpeechEngine.partialContinues("just of a long sentence", ""))
    }

    @Test
    fun droppedWordsNewChunkIsNotContinuation() {
        // recognizer jumps to a shorter unrelated chunk after a pause -> commit the previous one
        assertFalse(AndroidSpeechEngine.partialContinues("just of a long sentence", "but"))
    }

    @Test
    fun sameLengthRewordIsContinuation() {
        // same word count, no shared prefix -> a re-hypothesis of the same speech (replace, no commit)
        assertTrue(AndroidSpeechEngine.partialContinues("the cat sat", "the cat sad"))
    }
}
