package com.akram.ecosystem.core

import java.security.MessageDigest

/**
 * Pure pairing state machine. See docs/protocol.md §5.
 * Owns no I/O: callers feed [Input]s and execute the returned [Effect]s.
 */
class PairingEngine(
    private val role: Role,
    ownDer: ByteArray,
    peerDer: ByteArray,
) {
    enum class Role { INITIATOR, RESPONDER }

    sealed interface State {
        data object Idle : State
        data object Requested : State
        data object CodeDisplayed : State
        data object ConfirmedLocal : State
        data object Paired : State
        data class Failed(val reason: String) : State
    }

    sealed interface Input {
        data object Start : Input
        data class ReceivedRequest(val fingerprint: String) : Input
        data object ReceivedAccept : Input
        data object ReceivedReject : Input
        data object ReceivedConfirm : Input
        data class ReceivedAbort(val reason: String?) : Input
        data object UserAccepted : Input
        data object UserConfirmed : Input
        data object UserRejected : Input
    }

    sealed interface Effect {
        data class Send(val message: Message) : Effect
        data class ShowAcceptPrompt(val fingerprint: String) : Effect
        data class DisplayCode(val code: String) : Effect
        data object PersistPeerCert : Effect
        data object Complete : Effect
        data class Fail(val reason: String) : Effect
    }

    var state: State = State.Idle
        private set

    private var peerConfirmed = false

    @OptIn(ExperimentalStdlibApi::class)
    private val ownFingerprint =
        MessageDigest.getInstance("SHA-256").digest(ownDer).toHexString()

    private val code = PairingCode.derive(ownDer, peerDer)

    fun handle(input: Input): List<Effect> {
        if (state == State.Paired || state is State.Failed) return emptyList()

        val s = state
        return when {
            // --- Initiator ---
            s == State.Idle && input == Input.Start && role == Role.INITIATOR -> {
                state = State.Requested
                listOf(Effect.Send(Message.PairRequest(PairRequestPayload(ownFingerprint))))
            }
            s == State.Requested && input == Input.ReceivedAccept && role == Role.INITIATOR -> {
                state = State.CodeDisplayed
                listOf(Effect.DisplayCode(code))
            }
            s == State.Requested && input == Input.ReceivedReject && role == Role.INITIATOR ->
                fail("rejected")

            // --- Responder ---
            s == State.Idle && input is Input.ReceivedRequest && role == Role.RESPONDER -> {
                state = State.Requested
                listOf(Effect.ShowAcceptPrompt(input.fingerprint))
            }
            s == State.Requested && input == Input.UserAccepted && role == Role.RESPONDER -> {
                state = State.CodeDisplayed
                listOf(Effect.Send(Message.PairAccept), Effect.DisplayCode(code))
            }
            s == State.Requested && input == Input.UserRejected && role == Role.RESPONDER -> {
                state = State.Failed("rejected")
                listOf(Effect.Send(Message.PairReject), Effect.Fail("rejected"))
            }

            // --- Shared confirmation dance ---
            s == State.CodeDisplayed && input == Input.UserConfirmed -> {
                if (peerConfirmed) {
                    state = State.Paired
                    listOf(
                        Effect.Send(Message.PairConfirm),
                        Effect.PersistPeerCert,
                        Effect.Complete)
                } else {
                    state = State.ConfirmedLocal
                    listOf(Effect.Send(Message.PairConfirm))
                }
            }
            s == State.CodeDisplayed && input == Input.ReceivedConfirm -> {
                peerConfirmed = true
                emptyList()
            }
            s == State.ConfirmedLocal && input == Input.ReceivedConfirm -> {
                state = State.Paired
                listOf(Effect.PersistPeerCert, Effect.Complete)
            }

            // --- Cancellation, any non-terminal state ---
            input is Input.ReceivedAbort -> fail(input.reason ?: "aborted")
            input == Input.UserRejected -> {
                state = State.Failed("rejected")
                listOf(
                    Effect.Send(Message.PairAbort(PairAbortPayload("rejected"))),
                    Effect.Fail("rejected"))
            }

            else -> emptyList()
        }
    }

    private fun fail(reason: String): List<Effect> {
        state = State.Failed(reason)
        return listOf(Effect.Fail(reason))
    }
}
