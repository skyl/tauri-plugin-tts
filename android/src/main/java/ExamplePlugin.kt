package space.httpjames.tauri_plugin_tts

import android.app.Activity
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
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
}

@TauriPlugin
class ExamplePlugin(private val activity: Activity): Plugin(activity) {
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

            // Set language if provided
            args.language?.let { lang ->
                try {
                    val locale = Locale.forLanguageTag(lang)
                    Log.d("TTS", "Requested language: $lang → Parsed locale: $locale")

                    val result = tts?.setLanguage(locale)
                    if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                        Log.e("TTS", "Language not supported or missing data: $lang")
                        invoke.reject("Language not supported: $lang")
                        return
                    }
                } catch (e: Exception) {
                    Log.e("TTS", "Invalid language tag: $lang", e)
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
                Log.e("TTS", "Failed to queue speech for text: ${args.text}")
                invoke.reject("Failed to queue speech")
            }

        } catch (e: Exception) {
            Log.e("TTS", "Unexpected exception", e)
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
