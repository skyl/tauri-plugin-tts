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

            // Set rate if provided (quadratic mapping: 0.5->0.5f, 1.0->1.0f, 1.5->3.0f)
            args.rate?.let { rate ->
                // // Clamp TypeScript rate to 0.0–1.5 (matches browser/iOS)
                // val clampedRate = rate.coerceIn(0.0f, 1.5f)
                // // Quadratic mapping: androidRate = 3.0 * rate^2 - 3.5 * rate + 1.5
                // val androidRate = (3.0f * clampedRate * clampedRate - 3.5f * clampedRate + 1.5f)
                //     .coerceIn(0.5f, 3.0f) // Ensure no invalid rates
                tts?.setSpeechRate(rate + 0.01f)
            } ?: tts?.setSpeechRate(1.0f) // Default to 1.0 if not provided

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