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
class SpeakArgs {
    var text: String = ""
    var language: String? = null
}

@TauriPlugin
class ExamplePlugin(private val activity: Activity) : Plugin(activity) {
    private var tts: TextToSpeech? = null
    private var isInitialized = false

    override fun load(webView: WebView) {
        Log.e("TTS", "🚨 load() called")
        initializeTTS()
    }

    private fun initializeTTS() {
        Log.e("TTS", "🚨 initializeTTS() starting")
        tts = TextToSpeech(activity) { status ->
            Log.e("TTS", "🚨 TTS init status = $status")
            isInitialized = status == TextToSpeech.SUCCESS
            if (isInitialized) {
                Log.e("TTS", "🚨 TTS successfully initialized")
                tts?.language = Locale.US
                val event = JSObject()
                event.put("initialized", true)
                trigger("ttsInitialized", event)
            } else {
                Log.e("TTS", "🚨 TTS failed to initialize")
                val event = JSObject()
                event.put("error", "Failed to initialize TTS")
                trigger("ttsError", event)
            }
        }
    }

    @Command
    fun speak(invoke: Invoke) {
        Log.e("TTS", "🚨 speak() called")
        Log.e("TTS", "🚨 RAW JSON from invoke: ${invoke.json()}")

        if (!isInitialized || tts == null) {
            Log.e("TTS", "🚨 TTS not initialized")
            invoke.reject("TTS not initialized")
            return
        }

        try {
            val args = invoke.parseArgs(SpeakArgs::class.java)
            Log.e("TTS", "🚨 Parsed args: text='${args.text}', language='${args.language}'")

            args.language?.let { lang ->
                try {
                    val locale = Locale.forLanguageTag(lang)
                    Log.e("TTS", "🚨 Requested language: $lang → Parsed locale: $locale")

                    val result = tts?.setLanguage(locale)
                    Log.e("TTS", "🚨 setLanguage() result = $result")

                    if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                        Log.e("TTS", "🚨 Language not supported or missing data: $lang")
                        invoke.reject("Language not supported: $lang")
                        return
                    }
                } catch (e: Exception) {
                    Log.e("TTS", "🚨 Invalid language tag: $lang", e)
                    invoke.reject("Invalid language code: $lang")
                    return
                }
            }

            val utteranceId = UUID.randomUUID().toString()
            Log.e("TTS", "🚨 Speaking utterance ID = $utteranceId")

            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    Log.e("TTS", "🚨 onStart called")
                    val event = JSObject()
                    event.put("status", "started")
                    trigger("ttsStatus", event)
                }

                override fun onDone(utteranceId: String?) {
                    Log.e("TTS", "🚨 onDone called")
                    invoke.resolve(null) // ensure compatibility with Tauri Rust layer
                }

                override fun onError(utteranceId: String?) {
                    Log.e("TTS", "🚨 onError called")
                    invoke.reject("Speech failed")
                }
            })

            val result = tts?.speak(args.text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
            Log.e("TTS", "🚨 speak() result = $result")

            if (result == TextToSpeech.ERROR) {
                Log.e("TTS", "🚨 Failed to queue speech for text: ${args.text}")
                invoke.reject("Failed to queue speech")
            }

        } catch (e: Exception) {
            Log.e("TTS", "🚨 Unexpected exception", e)
            invoke.reject(e.message ?: "Unknown error")
        }
    }

    @Command
    fun stop(invoke: Invoke) {
        Log.e("TTS", "🚨 stop() called")
        tts?.stop()
        invoke.resolve()
    }

    // override fun destroy() {
    //     Log.e("TTS", "🚨 destroy() called")
    //     tts?.stop()
    //     tts?.shutdown()
    //     super.destroy()
    // }
}
