package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** Explicit host objects, unlike ordinary input maps, retain identity and write through immediately. */
internal interface JsMutableObject {
    val propertyNames: List<String>
    val methodNames: List<String>
    val hasDynamicProperties: Boolean get() = false

    fun getProperty(name: String): Any?
    fun setProperty(name: String, value: Any?)
    fun invoke(name: String, arguments: List<Any?>): Any?
    fun removeProperty(name: String): Boolean = error("Property cannot be removed: $name")
    fun updateExecutionContext(context: CoroutineContext) = Unit
}

internal class QuickJsMutableObjectBridge {
    private val ids = HashMap<JsMutableObject, Int>()
    private val objects = ArrayList<JsMutableObject>()
    var executionContext: CoroutineContext = EmptyCoroutineContext

    suspend fun install(engine: QuickJs) {
        engine.function("__legadoMutableObjectCall") { arguments ->
            executionContext.ensureActive()
            val target = objects[(arguments[0] as Number).toInt()]
            target.updateExecutionContext(executionContext)
            val operation = arguments[1] as String
            val name = arguments[2] as String
            val values = (Json.parseToJsonElement(arguments[3] as String) as JsonArray).map(::decodeArgument)
            val value = when (operation) {
                "get" -> target.getProperty(name)
                "set" -> { target.setProperty(name, values.firstOrNull()); null }
                "call" -> target.invoke(name, values)
                "keys" -> target.propertyNames
                "remove" -> target.removeProperty(name)
                else -> error("Unknown mutable object operation: $operation")
            }
            encodeResult(value).toString()
        }
        engine.evaluate<Any?>(MUTABLE_OBJECT_SUPPORT)
    }

    fun clear() {
        ids.clear()
        objects.clear()
        executionContext = EmptyCoroutineContext
    }

    fun literal(value: Any?): String = when (value) {
        null -> "null"
        is JsMutableObject -> "globalThis.__legadoMutableObjectBind(${descriptor(value)})"
        is String -> JsonPrimitive(value).toString()
        is Number, is Boolean -> value.toString()
        is Map<*, *> -> value.entries.joinToString(prefix = "({", postfix = "})") { (key, item) ->
            "[${JsonPrimitive(key.toString())}]:${literal(item)}"
        }
        is Iterable<*> -> value.joinToString(prefix = "[", postfix = "]") { literal(it) }
        is Array<*> -> value.joinToString(prefix = "[", postfix = "]") { literal(it) }
        else -> JsonPrimitive(value.toString()).toString()
    }

    private fun descriptor(value: JsMutableObject): JsonObject {
        value.updateExecutionContext(executionContext)
        val id = ids.getOrPut(value) { objects.size.also { objects.add(value) } }
        return JsonObject(mapOf(
            "id" to JsonPrimitive(id),
            "properties" to encode(value.propertyNames),
            "methods" to encode(value.methodNames),
            "dynamic" to JsonPrimitive(value.hasDynamicProperties)
        ))
    }

    // A snapshot array can contain live host entries without serializing their identity away.
    private fun encodeResult(value: Any?): JsonObject = when (value) {
        is JsMutableObject -> JsonObject(mapOf("binding" to descriptor(value)))
        is Map<*, *> -> JsonObject(mapOf(
            "object" to JsonObject(value.entries.associate { it.key.toString() to encodeResult(it.value) })
        ))
        is Iterable<*> -> JsonObject(mapOf("array" to JsonArray(value.map(::encodeResult))))
        is Array<*> -> JsonObject(mapOf("array" to JsonArray(value.map(::encodeResult))))
        else -> JsonObject(mapOf("value" to encode(value)))
    }

    // Only direct host arguments are references; ordinary map/array arguments keep JSON snapshot semantics.
    private fun decodeArgument(value: JsonElement): Any? {
        val argument = value as JsonObject
        val reference = argument["reference"]
        return if (reference != null) {
            objects[(reference as JsonPrimitive).content.toInt()]
        } else {
            decode(argument["value"] ?: JsonNull)
        }
    }

    private fun encode(value: Any?): JsonElement = when (value) {
        null -> JsonNull
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Map<*, *> -> JsonObject(value.entries.associate { it.key.toString() to encode(it.value) })
        is Iterable<*> -> JsonArray(value.map(::encode))
        is Array<*> -> JsonArray(value.map(::encode))
        else -> error("Unsupported mutable object result: ${value::class}")
    }

    private fun decode(value: JsonElement): Any? = when (value) {
        JsonNull -> null
        is JsonPrimitive -> if (value.isString) value.content else {
            value.booleanOrNull ?: value.longOrNull ?: value.doubleOrNull ?: value.content
        }
        is JsonArray -> value.map(::decode)
        is JsonObject -> value.mapValues { decode(it.value) }
    }
}

private val MUTABLE_OBJECT_SUPPORT = """
    (function(global, call, parse, stringify, define, ownKeys, hasOwn) {
      delete global.__legadoMutableObjectCall;
      var objects = Object.create(null);
      var references = new WeakMap();
      function argument(value) {
        if (value !== null && (typeof value === 'object' || typeof value === 'function') && references.has(value)) {
          return { reference: references.get(value) };
        }
        return { value: value };
      }
      function result(value) {
        if (value.binding) return bind(value.binding);
        if (value.array) return value.array.map(result);
        if (value.object) {
          var object = {};
          Object.keys(value.object).forEach(function(key) {
            define(object, key, { value: result(value.object[key]), enumerable: true, configurable: true, writable: true });
          });
          return object;
        }
        return value.value;
      }
      function bind(descriptor) {
        var id = descriptor.id;
        if (objects[id]) return objects[id];
        function send(operation, name, args) {
          return result(parse(call(id, operation, name, stringify(args.map(argument)))));
        }
        var target = Object.create(null);
        descriptor.methods.filter(function(name, index, names) {
          return names.indexOf(name) === index;
        }).forEach(function(name) {
          define(target, name, {
            value: function() { return send('call', name, Array.prototype.slice.call(arguments)); }
          });
        });
        if (descriptor.dynamic) {
          target = new Proxy(target, {
            get: function(target, key) {
              if (typeof key !== 'string' || hasOwn.call(target, key)) return target[key];
              return send('get', key, []);
            },
            set: function(target, key, value) {
              if (typeof key !== 'string' || hasOwn.call(target, key)) return false;
              send('set', key, [value]);
              return true;
            },
            deleteProperty: function(target, key) {
              if (typeof key !== 'string' || hasOwn.call(target, key)) return false;
              return send('remove', key, []);
            },
            ownKeys: function(target) {
              return ownKeys(target).concat(send('keys', '', []).filter(function(key) {
                return !hasOwn.call(target, key);
              }));
            },
            getOwnPropertyDescriptor: function(target, key) {
              if (hasOwn.call(target, key)) return Object.getOwnPropertyDescriptor(target, key);
              if (typeof key === 'string' && send('keys', '', []).indexOf(key) >= 0) {
                return { configurable: true, enumerable: true, writable: true, value: send('get', key, []) };
              }
            }
          });
        } else {
          descriptor.properties.forEach(function(name) {
            define(target, name, {
              enumerable: true,
              get: function() { return send('get', name, []); },
              set: function(value) { send('set', name, [value]); }
            });
          });
        }
        objects[id] = target;
        references.set(target, id);
        return target;
      }
      define(global, '__legadoMutableObjectBind', { value: bind });
    })(globalThis, globalThis.__legadoMutableObjectCall, JSON.parse, JSON.stringify,
       Object.defineProperty, Reflect.ownKeys, Object.prototype.hasOwnProperty);
""".trimIndent()
