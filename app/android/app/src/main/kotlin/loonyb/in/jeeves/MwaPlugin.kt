package loonyb.`in`.jeeves

import android.net.Uri
import androidx.activity.ComponentActivity
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.solana.mobilewalletadapter.clientlib.ConnectionIdentity
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
import kotlinx.coroutines.withContext
import java.util.Base64

/**
 * Bridges Dart <-> Mobile Wallet Adapter (MWA) clientlib-ktx 2.0.3.
 *
 * Channel: "jeeves/mwa"
 *   getPublicKey() -> String  (base58)
 *   sign({ message: base64 }) -> { publicKey: base58, signature: base64 }
 *   clearAuth() -> null       (drops cached auth token)
 *
 * Notes:
 * - The MWA adapter is long-lived and its `authToken` is reused between
 *   getPublicKey() and sign(), so the user only sees the wallet picker once
 *   per sign-in attempt.
 * - Public keys are base58 to match the backend's `sws_strategy.py`, which
 *   calls `base58.b58decode(public_key_b58)` before ed25519 verification.
 * - `ActivityResultSender` registers an ActivityResultLauncher, which must be
 *   done before the host activity reaches STARTED. We create it in
 *   `onAttachedToActivity`, which the Flutter embedding invokes during
 *   `Activity.onCreate` (via FlutterFragmentActivity#configureFlutterEngine).
 */
class MwaPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var activitySender: ActivityResultSender? = null
    private var mwa: MobileWalletAdapter? = null

    companion object {
        private val IDENTITY_URI = Uri.parse("https://jeeves.app")
        // Must be RELATIVE to IDENTITY_URI — the MWA clientlib validates this
        // and throws `IllegalArgumentException: If non-null, iconRelativeUri
        // must be a relative Uri` if an absolute URL is passed here.
        private val ICON_URI = Uri.parse("favicon.ico")
        private const val APP_NAME = "Jeeves"
    }

    // ---- FlutterPlugin ----------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "jeeves/mwa")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ---- ActivityAware ----------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        val activity = binding.activity as? ComponentActivity
            ?: error("MwaPlugin requires a ComponentActivity host")
        activitySender = ActivityResultSender(activity)
        mwa = MobileWalletAdapter(
            connectionIdentity = ConnectionIdentity(
                identityUri = IDENTITY_URI,
                iconUri = ICON_URI,
                identityName = APP_NAME,
            ),
        )
    }

    override fun onDetachedFromActivity() {
        activitySender = null
        mwa = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    // ---- MethodChannel ----------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val sender = activitySender
        val adapter = mwa
        if (sender == null || adapter == null) {
            result.error("NO_ACTIVITY", "MWA host activity not ready", null)
            return
        }

        when (call.method) {
            "getPublicKey" -> getPublicKey(adapter, sender, result)
            "sign" -> {
                val messageB64 = call.argument<String>("message")
                if (messageB64 == null) {
                    result.error("INVALID_ARGS", "Missing message", null)
                    return
                }
                sign(adapter, sender, messageB64, result)
            }
            "clearAuth" -> {
                adapter.authToken = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---- Operations -------------------------------------------------------

    private fun getPublicKey(
        mwa: MobileWalletAdapter,
        sender: ActivityResultSender,
        result: MethodChannel.Result,
    ) {
        CoroutineScope(Dispatchers.IO).launch {
            // `transact` handles authorize/reauthorize based on `mwa.authToken`
            // and invokes this block with AdapterOperations as receiver and the
            // resulting AuthorizationResult as the single argument.
            val outcome = mwa.transact(sender) { auth -> auth.publicKey }
            dispatch(outcome, result) { pubKey ->
                Base58.encode(pubKey)
            }
        }
    }

    private fun sign(
        mwa: MobileWalletAdapter,
        sender: ActivityResultSender,
        messageB64: String,
        result: MethodChannel.Result,
    ) {
        val messageBytes = Base64.getDecoder().decode(messageB64)
        CoroutineScope(Dispatchers.IO).launch {
            val outcome = mwa.transact(sender) { auth ->
                val signed = signMessagesDetached(
                    arrayOf(messageBytes),
                    arrayOf(auth.publicKey),
                )
                Pair(auth.publicKey, signed.messages[0].signatures[0])
            }
            dispatch(outcome, result) { (pubKey, sig) ->
                mapOf(
                    "publicKey" to Base58.encode(pubKey),
                    "signature" to Base64.getEncoder().encodeToString(sig),
                )
            }
        }
    }

    /**
     * Converts a [TransactionResult] into a MethodChannel reply on the main
     * thread, mapping the success payload with [transform] and surfacing error
     * details for anything else. Clears the cached auth token on non-success
     * outcomes so the next attempt starts from a clean state.
     */
    private suspend fun <T, R> dispatch(
        outcome: TransactionResult<T>,
        result: MethodChannel.Result,
        transform: (T) -> R,
    ) = withContext(Dispatchers.Main) {
        when (outcome) {
            is TransactionResult.Success -> {
                result.success(transform(outcome.payload))
            }
            is TransactionResult.Failure -> {
                mwa?.authToken = null
                val msg = outcome.message ?: outcome.e.message ?: "MWA failure"
                result.error("MWA_ERROR", msg, null)
            }
            is TransactionResult.NoWalletFound -> {
                result.error(
                    "MWA_NO_WALLET",
                    outcome.message ?: "No MWA-compatible wallet installed",
                    null,
                )
            }
        }
    }
}

/**
 * Bitcoin-style base58 encoder (Solana public-key compatible).
 *
 * Inline to avoid pulling another Android dep for ~30 lines. Matches the
 * `base58` pub.dev package and what PyNaCl pairs with on the backend
 * (`base58.b58decode(public_key_b58)` in `sws_strategy.py`).
 */
private object Base58 {
    private const val ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    fun encode(input: ByteArray): String {
        if (input.isEmpty()) return ""

        var zeros = 0
        while (zeros < input.size && input[zeros].toInt() == 0) zeros++

        val bytes = input.copyOf()
        val encoded = CharArray(input.size * 2)
        var outIndex = encoded.size

        var start = zeros
        while (start < bytes.size) {
            var remainder = 0
            for (i in start until bytes.size) {
                val value = (bytes[i].toInt() and 0xff) + remainder * 256
                bytes[i] = (value / 58).toByte()
                remainder = value % 58
            }
            encoded[--outIndex] = ALPHABET[remainder]
            if (bytes[start].toInt() == 0) start++
        }

        repeat(zeros) { encoded[--outIndex] = ALPHABET[0] }

        return String(encoded, outIndex, encoded.size - outIndex)
    }
}
