package loonyb.`in`.jeeves

import android.content.Intent
import android.net.Uri
import android.util.Base64
import androidx.activity.result.ActivityResult
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.solana.mobilewalletadapter.clientlib.MobileWalletAdapter
import com.solana.mobilewalletadapter.clientlib.RpcCluster
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.*

/**
 * Flutter plugin that exposes Mobile Wallet Adapter (MWA) signing to Dart via
 * a MethodChannel ("jeeves/mwa").
 *
 * Dependency (add to app/build.gradle.kts):
 *   implementation("com.solanamobile:mobile-wallet-adapter-clientlib-ktx:2.0.3")
 *
 * Methods exposed on channel "jeeves/mwa":
 *   getPublicKey() → String (base58 public key)
 *   sign({message: base64String}) → {publicKey: String, signature: base64String}
 */
class MwaPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    companion object {
        private const val CHANNEL = "jeeves/mwa"
        private const val MWA_REQUEST_CODE = 0x4d574101
        private val IDENTITY_URI = Uri.parse("https://jeeves.app")
        private const val IDENTITY_NAME = "Jeeves"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivity() {
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding = null
    }

    private fun makeSender(binding: ActivityPluginBinding): ActivityResultSender {
        var pendingCallback: ((ActivityResult) -> Unit)? = null
        val listener = PluginRegistry.ActivityResultListener { requestCode, resultCode, data ->
            if (requestCode == MWA_REQUEST_CODE) {
                pendingCallback?.invoke(ActivityResult(resultCode, data))
                pendingCallback = null
                true
            } else {
                false
            }
        }
        binding.addActivityResultListener(listener)
        return ActivityResultSender { intent: Intent, onResult: (ActivityResult) -> Unit ->
            pendingCallback = onResult
            binding.activity.startActivityForResult(intent, MWA_REQUEST_CODE)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val binding = activityBinding
            ?: return result.error("NO_ACTIVITY", "Activity not attached", null)

        val mwa = MobileWalletAdapter()
        val sender = makeSender(binding)

        when (call.method) {
            "getPublicKey" -> scope.launch {
                runCatching {
                    mwa.transact(sender) {
                        val auth = authorize(
                            identityUri = IDENTITY_URI,
                            iconUri = null,
                            identityName = IDENTITY_NAME,
                            rpcCluster = RpcCluster.MainnetBeta,
                        )
                        Base58.encode(auth.publicKey.bytes)
                    }
                }.onSuccess { pk ->
                    withContext(Dispatchers.Main) { result.success(pk) }
                }.onFailure { e ->
                    withContext(Dispatchers.Main) {
                        result.error("MWA_ERROR", e.message, null)
                    }
                }
            }

            "sign" -> {
                val msgB64 = call.argument<String>("message")
                    ?: return result.error("MISSING_ARG", "message required", null)
                val msgBytes = Base64.decode(msgB64, Base64.NO_WRAP)

                scope.launch {
                    runCatching {
                        mwa.transact(sender) {
                            val auth = authorize(
                                identityUri = IDENTITY_URI,
                                iconUri = null,
                                identityName = IDENTITY_NAME,
                                rpcCluster = RpcCluster.MainnetBeta,
                            )
                            val signed = signMessages(
                                messages = arrayOf(msgBytes),
                                addresses = arrayOf(auth.publicKey.bytes),
                            )
                            mapOf(
                                "publicKey" to Base58.encode(auth.publicKey.bytes),
                                "signature" to Base64.encodeToString(
                                    signed.messages[0].signedPayload,
                                    Base64.NO_WRAP,
                                ),
                            )
                        }
                    }.onSuccess { r ->
                        withContext(Dispatchers.Main) { result.success(r) }
                    }.onFailure { e ->
                        withContext(Dispatchers.Main) {
                            result.error("MWA_ERROR", e.message, null)
                        }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }
}

private object Base58 {
    private const val ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private val BASE = java.math.BigInteger.valueOf(58)
    private val ZERO = java.math.BigInteger.ZERO

    fun encode(input: ByteArray): String {
        var value = java.math.BigInteger(1, input)
        val sb = StringBuilder()
        while (value > ZERO) {
            val (q, r) = value.divideAndRemainder(BASE)
            sb.append(ALPHABET[r.toInt()])
            value = q
        }
        repeat(input.takeWhile { it == 0.toByte() }.size) { sb.append(ALPHABET[0]) }
        return sb.reverse().toString()
    }
}
