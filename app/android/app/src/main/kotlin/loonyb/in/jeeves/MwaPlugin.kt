package loonyb.`in`.jeeves

import android.net.Uri
import androidx.activity.ComponentActivity
import com.solana.mobilewalletadapter.clientlib.MobileWalletAdapter
import com.solana.mobilewalletadapter.clientlib.Solana
import com.solana.mobilewalletadapter.clientlib.TransactionResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.Base64

class MwaPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null

    companion object {
        private val ICON_URI = Uri.parse("https://jeeves.app/icon.png")
        private const val APP_NAME = "Jeeves"
        private const val IDENTITY_URI = "https://jeeves.app"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "jeeves/mwa")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val activity = activityBinding?.activity as? ComponentActivity
        if (activity == null) {
            result.error("NO_ACTIVITY", "No ComponentActivity available", null)
            return
        }

        when (call.method) {
            "getPublicKey" -> getPublicKey(activity, result)
            "sign" -> {
                val message = call.argument<String>("message")
                if (message == null) {
                    result.error("INVALID_ARGS", "Missing message", null)
                    return
                }
                sign(activity, message, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun getPublicKey(activity: ComponentActivity, result: MethodChannel.Result) {
        CoroutineScope(Dispatchers.IO).launch {
            val mwa = MobileWalletAdapter()
            val outcome = mwa.transact(activity) {
                authorize(
                    identityUri = Uri.parse(IDENTITY_URI),
                    iconUri = ICON_URI,
                    identityName = APP_NAME,
                    rpcCluster = Solana.Mainnet,
                    connectionIdentity = byteArrayOf(),
                )
            }
            when (outcome) {
                is TransactionResult.Success -> {
                    val pubKeyB64 = Base64.getEncoder().encodeToString(outcome.payload.publicKey)
                    CoroutineScope(Dispatchers.Main).launch {
                        result.success(pubKeyB64)
                    }
                }
                is TransactionResult.Failure -> {
                    CoroutineScope(Dispatchers.Main).launch {
                        result.error("MWA_ERROR", outcome.e.message, null)
                    }
                }
                is TransactionResult.Cancelled -> {
                    CoroutineScope(Dispatchers.Main).launch {
                        result.error("MWA_CANCELLED", "User cancelled wallet interaction", null)
                    }
                }
            }
        }
    }

    private fun sign(activity: ComponentActivity, messageB64: String, result: MethodChannel.Result) {
        val messageBytes = Base64.getDecoder().decode(messageB64)
        CoroutineScope(Dispatchers.IO).launch {
            val mwa = MobileWalletAdapter()
            val outcome = mwa.transact(activity) {
                val auth = authorize(
                    identityUri = Uri.parse(IDENTITY_URI),
                    iconUri = ICON_URI,
                    identityName = APP_NAME,
                    rpcCluster = Solana.Mainnet,
                    connectionIdentity = byteArrayOf(),
                )
                val pubKey = auth.publicKey

                val signed = signMessages(
                    messages = arrayOf(messageBytes),
                    addresses = arrayOf(pubKey),
                )

                Pair(pubKey, signed.signedPayloads[0])
            }
            when (outcome) {
                is TransactionResult.Success -> {
                    val (pubKey, sig) = outcome.payload
                    val encoder = Base64.getEncoder()
                    val response = mapOf(
                        "publicKey" to encoder.encodeToString(pubKey),
                        "signature" to encoder.encodeToString(sig),
                    )
                    CoroutineScope(Dispatchers.Main).launch {
                        result.success(response)
                    }
                }
                is TransactionResult.Failure -> {
                    CoroutineScope(Dispatchers.Main).launch {
                        result.error("MWA_ERROR", outcome.e.message, null)
                    }
                }
                is TransactionResult.Cancelled -> {
                    CoroutineScope(Dispatchers.Main).launch {
                        result.error("MWA_CANCELLED", "User cancelled wallet interaction", null)
                    }
                }
            }
        }
    }
}
