package com.akram.ecosystem.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/** Advertises the TLS server on the LAN as `_ecosys._tcp`. See docs/protocol.md §1. */
class NsdAdvertiser(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null

    fun register(port: Int, deviceId: String, deviceName: String, protocolVersion: Int) {
        unregister()
        val info = NsdServiceInfo().apply {
            serviceName = "Ecosystem-$deviceName"
            serviceType = "_ecosys._tcp"
            setPort(port)
            setAttribute("deviceId", deviceId)
            setAttribute("name", deviceName)
            setAttribute("protocolVersion", protocolVersion.toString())
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {
                Log.i(TAG, "registered as ${i.serviceName} on port $port")
            }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) {
                Log.e(TAG, "registration failed: $code")
            }
            override fun onServiceUnregistered(i: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) = Unit
        }
        listener = l
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun unregister() {
        listener?.let { runCatching { nsd.unregisterService(it) } }
        listener = null
    }

    private companion object {
        const val TAG = "NsdAdvertiser"
    }
}
