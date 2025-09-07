package space.httpjames.tauri_plugin_tts

import android.app.Activity
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.webkit.WebView
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Plugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import java.util.Locale
import java.util.UUID

import kotlin.math.ln

private fun mapWebRateToAndroid(
    webRate: Float,
    targetMax: Float = 2.0f   // push 1.5 → ~3.0 for clearly-fast speech
): Float {
    // Web semantics
    val W_MIN = 0.10f
    val W_DEF = 1.00f
    val W_MAX = 1.50f

    // Android semantics (relative multiplier; engines vary)
    val A_MIN = 0.10f
    val A_DEF = 1.00f
    val A_MAX = targetMax

    // small headroom to avoid edge weirdness in some engines
    val pad = 0.02f * (A_MAX - A_MIN)
    val lo = A_MIN + pad
    val hi = A_MAX - pad

    val w = webRate.coerceIn(W_MIN, W_MAX)

    if (kotlin.math.abs(w - W_DEF) < 1e-6f) return A_DEF

    return if (w < W_DEF) {
        // [0.1..1.0) → [lo..A_DEF] (log scale)
        val progress = (ln((w / W_MIN).toDouble()) / ln((W_DEF / W_MIN).toDouble())).toFloat()
        lo + progress * (A_DEF - lo)
    } else {
        // (1.0..1.5] → [A_DEF..hi] (log scale)
        val progress = (ln((w / W_DEF).toDouble()) / ln((W_MAX / W_DEF).toDouble())).toFloat()
        A_DEF + progress * (hi - A_DEF)
    }
}

@InvokeArg
internal class SpeakArgs {
    lateinit var text: String
    var language: String? = null
    var rate: Float? = null // Optional rate (0.0 to 1.5, maps quadratically to 0.5–3.0)
}

@TauriPlugin
class ExamplePlugin(private val activity: Activity) : Plugin(activity) {
    private var tts: TextToSpeech? = null
    private var isInitialized = false

    override fun load(webView: WebView) {
        initializeTTS()
    }

    private fun initializeTTS() {
        tts = TextToSpeech(activity) { status ->
            isInitialized = status == TextToSpeech.SUCCESS
            if (isInitialized) {
                tts?.language = Locale.US
                val event = JSObject()
                event.put("initialized", true)
                trigger("ttsInitialized", event)
            } else {
                val event = JSObject()
                event.put("error", "Failed to initialize TTS")
                trigger("ttsError", event)
            }
        }
    }

    @Command
    fun speak(invoke: Invoke) {
        if (!isInitialized || tts == null) {
            invoke.reject("TTS not initialized")
            return
        }

        try {
            val args = invoke.parseArgs(SpeakArgs::class.java)

            args.rate?.let { rate ->
                val androidRate = mapWebRateToAndroid(rate, targetMax = 3.0f)
                tts?.setSpeechRate(androidRate)
            } ?: tts?.setSpeechRate(1.0f)


            // Language handling with fa -> ar fallback
            args.language?.let { lang ->
                try {
                    // Try primary language (e.g., "fa" or "fa-IR")
                    val locale = Locale.forLanguageTag(lang)
                    var result = tts?.setLanguage(locale)
                    if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                        // Fallback to Arabic if Farsi ("fa") requested
                        if (lang.lowercase().startsWith("fa")) {
                            val fallbackLocale = Locale("ar")
                            result = tts?.setLanguage(fallbackLocale)
                            if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                                invoke.reject("Neither Farsi nor Arabic supported")
                                return
                            }
                            // Notify TypeScript of fallback
                            val ret = JSObject()
                            ret.put("fallback", JSObject().apply {
                                put("wanted", "fa")
                                put("used", "ar")
                            })
                            trigger("ttsLanguageFallback", ret)
                        } else {
                            invoke.reject("Language not supported: $lang")
                            return
                        }
                    }
                } catch (e: Exception) {
                    invoke.reject("Invalid language code: $lang")
                    return
                }
            }

            val utteranceId = UUID.randomUUID().toString()

            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    val event = JSObject()
                    event.put("status", "started")
                    trigger("ttsStatus", event)
                }

                override fun onDone(utteranceId: String?) {
                    val ret = JSObject()
                    ret.put("success", true)
                    invoke.resolve(ret)
                }

                override fun onError(utteranceId: String?) {
                    invoke.reject("Speech failed")
                }
            })

            val result = tts?.speak(args.text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
            if (result == TextToSpeech.ERROR) {
                invoke.reject("Failed to queue speech")
            }

        } catch (e: Exception) {
            invoke.reject(e.message ?: "Unknown error")
        }
    }

    @Command
    fun stop(invoke: Invoke) {
        tts?.stop()
        invoke.resolve()
    }

    // override fun destroy() {
    //     tts?.stop()
    //     tts?.shutdown()
    //     super.destroy()
    // }
}