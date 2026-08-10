package com.akram.ecosystem.core

import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private val derMac = byteArrayOf(0x30, 0x82.toByte(), 0x01, 0x0a, 0x02, 0x81.toByte())
private val derPhone = byteArrayOf(0x30, 0x82.toByte(), 0x02, 0x0b, 0x03, 0x82.toByte())
private val expectedCode = PairingCode.derive(derMac, derPhone)

private fun macFingerprint(): String =
    MessageDigest.getInstance("SHA-256").digest(derMac).toHex()

class PairingEngineResponderTest {
    private fun makeEngine() =
        PairingEngine(PairingEngine.Role.RESPONDER, ownDer = derPhone, peerDer = derMac)

    @Test
    fun happyPath() {
        val engine = makeEngine()

        val e1 = engine.handle(PairingEngine.Input.ReceivedRequest(macFingerprint()))
        assertEquals(listOf(PairingEngine.Effect.ShowAcceptPrompt(macFingerprint())), e1)
        assertEquals(PairingEngine.State.Requested, engine.state)

        val e2 = engine.handle(PairingEngine.Input.UserAccepted)
        assertEquals(
            listOf(
                PairingEngine.Effect.Send(Message.PairAccept),
                PairingEngine.Effect.DisplayCode(expectedCode)),
            e2)
        assertEquals(PairingEngine.State.CodeDisplayed, engine.state)

        val e3 = engine.handle(PairingEngine.Input.UserConfirmed)
        assertEquals(listOf(PairingEngine.Effect.Send(Message.PairConfirm)), e3)
        assertEquals(PairingEngine.State.ConfirmedLocal, engine.state)

        val e4 = engine.handle(PairingEngine.Input.ReceivedConfirm)
        assertEquals(
            listOf(PairingEngine.Effect.PersistPeerCert, PairingEngine.Effect.Complete), e4)
        assertEquals(PairingEngine.State.Paired, engine.state)
    }

    @Test
    fun peerConfirmArrivesBeforeLocalConfirm() {
        val engine = makeEngine()
        engine.handle(PairingEngine.Input.ReceivedRequest(macFingerprint()))
        engine.handle(PairingEngine.Input.UserAccepted)

        assertTrue(engine.handle(PairingEngine.Input.ReceivedConfirm).isEmpty())
        assertEquals(PairingEngine.State.CodeDisplayed, engine.state)

        val e = engine.handle(PairingEngine.Input.UserConfirmed)
        assertEquals(
            listOf(
                PairingEngine.Effect.Send(Message.PairConfirm),
                PairingEngine.Effect.PersistPeerCert,
                PairingEngine.Effect.Complete),
            e)
        assertEquals(PairingEngine.State.Paired, engine.state)
    }

    @Test
    fun userRejectInRequestedSendsReject() {
        val engine = makeEngine()
        engine.handle(PairingEngine.Input.ReceivedRequest(macFingerprint()))
        val e = engine.handle(PairingEngine.Input.UserRejected)
        assertEquals(
            listOf(
                PairingEngine.Effect.Send(Message.PairReject),
                PairingEngine.Effect.Fail("rejected")),
            e)
        assertEquals(PairingEngine.State.Failed("rejected"), engine.state)
    }

    @Test
    fun abortMidFlowFails() {
        val engine = makeEngine()
        engine.handle(PairingEngine.Input.ReceivedRequest(macFingerprint()))
        engine.handle(PairingEngine.Input.UserAccepted)
        val e = engine.handle(PairingEngine.Input.ReceivedAbort("user cancelled"))
        assertEquals(listOf(PairingEngine.Effect.Fail("user cancelled")), e)
        assertEquals(PairingEngine.State.Failed("user cancelled"), engine.state)
    }

    @Test
    fun terminalStatesIgnoreInputs() {
        val engine = makeEngine()
        engine.handle(PairingEngine.Input.ReceivedRequest(macFingerprint()))
        engine.handle(PairingEngine.Input.UserAccepted)
        engine.handle(PairingEngine.Input.UserConfirmed)
        engine.handle(PairingEngine.Input.ReceivedConfirm)
        assertEquals(PairingEngine.State.Paired, engine.state)

        assertTrue(engine.handle(PairingEngine.Input.ReceivedAbort("x")).isEmpty())
        assertTrue(engine.handle(PairingEngine.Input.UserConfirmed).isEmpty())
        assertEquals(PairingEngine.State.Paired, engine.state)
    }
}

class PairingEngineInitiatorTest {
    private fun makeEngine() =
        PairingEngine(PairingEngine.Role.INITIATOR, ownDer = derMac, peerDer = derPhone)

    @Test
    fun happyPath() {
        val engine = makeEngine()

        val e1 = engine.handle(PairingEngine.Input.Start)
        assertEquals(
            listOf(PairingEngine.Effect.Send(
                Message.PairRequest(PairRequestPayload(macFingerprint())))),
            e1)
        assertEquals(PairingEngine.State.Requested, engine.state)

        val e2 = engine.handle(PairingEngine.Input.ReceivedAccept)
        assertEquals(listOf(PairingEngine.Effect.DisplayCode(expectedCode)), e2)

        val e3 = engine.handle(PairingEngine.Input.UserConfirmed)
        assertEquals(listOf(PairingEngine.Effect.Send(Message.PairConfirm)), e3)

        val e4 = engine.handle(PairingEngine.Input.ReceivedConfirm)
        assertEquals(
            listOf(PairingEngine.Effect.PersistPeerCert, PairingEngine.Effect.Complete), e4)
        assertEquals(PairingEngine.State.Paired, engine.state)
    }

    @Test
    fun rejectFails() {
        val engine = makeEngine()
        engine.handle(PairingEngine.Input.Start)
        val e = engine.handle(PairingEngine.Input.ReceivedReject)
        assertEquals(listOf(PairingEngine.Effect.Fail("rejected")), e)
        assertEquals(PairingEngine.State.Failed("rejected"), engine.state)
    }
}
