package io.legado.kmp.shared.scripting

// Insert after LEGACY_JS_JAVA_VALUES, inside the Java shim closure and before untrusted source code.
internal val LEGACY_JS_JAVA_IO = """
    var JByteArrayOutputStream, JByteArrayInputStream;
    (function() {
      var ioMaxBytes = 16777216;
      var ioPrivate = new WeakMap();
      var ioGet = Function.prototype.call.bind(WeakMap.prototype.get, ioPrivate);
      var ioSet = Function.prototype.call.bind(WeakMap.prototype.set, ioPrivate);
      var ioOutputPrototype = create(null), ioInputPrototype = create(null);

      function ioState(value, kind) {
        var data = value !== null && (typeof value === 'object' || typeof value === 'function') ? ioGet(value) : null;
        if (!data || data.kind !== kind) throw new fail('IllegalArgumentException: expected a supported ByteArray' + kind + 'Stream');
        if (data.busy) throw new fail('IllegalStateException: reentrant byte stream operation');
        return data;
      }
      function ioInt(value, name) {
        value = unbox(value);
        if (typeof value !== 'number' || !integer(value) || value < -2147483648 || value > 2147483647) {
          throw new outOfBounds(name + ' must be a Java int');
        }
        return value;
      }
      function ioByte(value) {
        value = unbox(value);
        if (typeof value !== 'number' || !integer(value) || value < -128 || value > 255) {
          throw new outOfBounds('Invalid Java byte value');
        }
        return value & 255;
      }
      function ioSource(value) {
        if (value == null) throw new fail('NullPointerException: expected a byte array');
        var source = byteSource(value);
        if (!source) throw new fail('Expected a byte array, ArrayBuffer, or 8-bit typed array');
        if (!integer(source.length) || source.length < 0 || source.length > ioMaxBytes) {
          throw new outOfBounds('Byte stream buffers are limited to 16777216 bytes');
        }
        return source;
      }
      function ioRange(source, offset, length) {
        offset = ioInt(offset, 'Byte stream offset');
        length = ioInt(length, 'Byte stream length');
        if (offset < 0 || length < 0 || offset > source.length || length > source.length - offset) {
          throw new outOfBounds('Byte stream range out of bounds');
        }
        var range = create(null);
        range.offset = offset; range.length = length;
        return range;
      }
      function ioArrayByte(source, at, writable) {
        var descriptor = descriptorOf(source.items, at);
        if (!descriptor || !own(descriptor, 'value')) {
          throw new fail('Expected a dense byte array with own data elements, not holes or accessors');
        }
        if (writable && !descriptor.writable) throw new fail('Byte stream output array must be writable');
        return ioByte(descriptor.value);
      }
      function ioValidate(source) {
        if (!source.array) return;
        for (var i = 0; i < source.length; i++) ioArrayByte(source, i, false);
      }
      function ioSnapshot(source, offset, length) {
        var bytes = new NativeUint8Array(length);
        for (var i = 0; i < length; i++) {
          bytes[i] = source.array ? ioArrayByte(source, offset + i, false) : ioByte(source.items[offset + i]);
        }
        return bytes;
      }
      function ioCapacity(data, extra) {
        if (extra > ioMaxBytes - data.count) throw new outOfBounds('ByteArrayOutputStream exceeds 16777216 bytes');
      }
      function ioAppend(data, bytes, length) {
        ioCapacity(data, length);
        var required = data.count + length;
        if (required > data.capacity) {
          var capacity = data.capacity === 0 ? 1 : data.capacity * 2;
          if (capacity < required) capacity = required;
          if (capacity > ioMaxBytes) capacity = ioMaxBytes;
          var grown = new NativeUint8Array(capacity);
          for (var i = 0; i < data.count; i++) grown[i] = data.buffer[i];
          data.buffer = grown; data.capacity = capacity;
        }
        for (var i = 0; i < length; i++) data.buffer[data.count + i] = bytes[i];
        data.count = required;
      }
      function ioSignedCopy(data) {
        var source = create(null);
        source.items = data.buffer; source.length = data.count; source.array = false;
        var bytes = copyBytes(source);
        for (var i = 0; i < bytes.length; i++) if (bytes[i] >= 128) bytes[i] -= 256;
        return bytes;
      }
      // Avoid Array.toJSON, species and other source-controlled hooks on private buffers.
      function ioBytesJson(data) {
        var output = '[';
        for (var i = 0; i < data.count; i++) output += (i ? ',' : '') + numberString(data.buffer[i], 10);
        return output + ']';
      }
      function ByteArrayOutputStream(size) {
        arity(arguments, 0, 1, 'ByteArrayOutputStream');
        size = arguments.length === 0 ? 32 : ioInt(size, 'ByteArrayOutputStream size');
        if (size < 0) throw new fail('IllegalArgumentException: negative ByteArrayOutputStream size');
        if (size > ioMaxBytes) throw new outOfBounds('ByteArrayOutputStream exceeds 16777216 bytes');
        var target = create(ioOutputPrototype), data = create(null);
        data.kind = 'Output'; data.buffer = new NativeUint8Array(size);
        data.capacity = size; data.count = 0; data.busy = false;
        ioSet(target, data);
        return target;
      }
      method(ioOutputPrototype, 'write', function(value, offset, length) {
        if (arguments.length !== 1 && arguments.length !== 3) throw new fail('Unsupported ByteArrayOutputStream.write overload');
        var data = ioState(this, 'Output');
        data.busy = true;
        try {
          var raw = unbox(value);
          if (arguments.length === 1 && typeof raw === 'number') {
            var byte = ioInt(raw, 'ByteArrayOutputStream.write byte') & 255;
            ioCapacity(data, 1);
            var single = new NativeUint8Array(1); single[0] = byte;
            ioAppend(data, single, 1);
            return;
          }
          var source = ioSource(value);
          var range = ioRange(source, arguments.length === 1 ? 0 : offset, arguments.length === 1 ? source.length : length);
          ioCapacity(data, range.length);
          // Validate and snapshot before changing the stream, including caller-owned mutable arrays.
          var bytes = ioSnapshot(source, range.offset, range.length);
          ioAppend(data, bytes, range.length);
        } finally { data.busy = false; }
      });
      method(ioOutputPrototype, 'toByteArray', function() {
        arity(arguments, 0, 0, 'ByteArrayOutputStream.toByteArray');
        var data = ioState(this, 'Output');
        data.busy = true;
        try { return ioSignedCopy(data); }
        finally { data.busy = false; }
      });
      method(ioOutputPrototype, 'size', function() {
        arity(arguments, 0, 0, 'ByteArrayOutputStream.size');
        return ioState(this, 'Output').count;
      });
      method(ioOutputPrototype, 'reset', function() {
        arity(arguments, 0, 0, 'ByteArrayOutputStream.reset');
        ioState(this, 'Output').count = 0;
      });
      method(ioOutputPrototype, 'close', function() {
        arity(arguments, 0, 0, 'ByteArrayOutputStream.close');
        ioState(this, 'Output');
      });
      method(ioOutputPrototype, 'toString', function(charset) {
        arity(arguments, 0, 1, 'ByteArrayOutputStream.toString');
        var data = ioState(this, 'Output');
        data.busy = true;
        try {
          var codec = null;
          if (arguments.length === 1) {
            if (charset == null) throw new fail('NullPointerException: expected a charset name');
            if (typeof unbox(charset) !== 'string') throw new fail('Expected a charset name string');
            codec = text(charset);
          }
          return bytesToStr(ioBytesJson(data), codec);
        } finally { data.busy = false; }
      });
      method(ioOutputPrototype, 'writeTo', function(output) {
        arity(arguments, 1, 1, 'ByteArrayOutputStream.writeTo');
        var data = ioState(this, 'Output');
        if (output == null) throw new fail('NullPointerException: missing output stream');
        var destination = output === this ? data : ioState(output, 'Output');
        // Only this module's actual output streams are supported; never trust a write method or __raw.
        ioAppend(destination, data.buffer, data.count);
      });
      ByteArrayOutputStream.prototype = ioOutputPrototype;

      function ByteArrayInputStream(value, offset, length) {
        if (arguments.length !== 1 && arguments.length !== 3) throw new fail('Unsupported ByteArrayInputStream overload');
        var source = ioSource(value);
        offset = arguments.length === 1 ? 0 : ioInt(offset, 'ByteArrayInputStream offset');
        length = arguments.length === 1 ? source.length : ioInt(length, 'ByteArrayInputStream length');
        if (offset < 0 || offset > source.length || length < 0 || length > 2147483647 - offset) {
          throw new outOfBounds('ByteArrayInputStream constructor range out of bounds');
        }
        ioValidate(source);
        var target = create(ioInputPrototype), data = create(null);
        // Keep the original carrier, not byteArray(value): later byte edits must remain visible.
        data.kind = 'Input'; data.value = value; data.length = source.length;
        data.position = offset; data.mark = offset;
        data.end = length > source.length - offset ? source.length : offset + length;
        data.busy = false;
        ioSet(target, data);
        return target;
      }
      function ioInputSource(data) {
        var source = ioSource(data.value);
        if (source.length !== data.length) throw new fail('ByteArrayInputStream backing buffer was resized or detached');
        return source;
      }
      function ioStore(output, offset, bytes, length) {
        'use strict';
        if (output.array) {
          for (var i = 0; i < length; i++) ioArrayByte(output, offset + i, true);
          for (var i = 0; i < length; i++) {
            var descriptor = create(null), byte = bytes[i];
            descriptor.value = byte >= 128 ? byte - 256 : byte;
            define(output.items, offset + i, descriptor);
          }
        } else {
          for (var i = 0; i < length; i++) output.items[offset + i] = bytes[i];
        }
      }
      method(ioInputPrototype, 'read', function(output, offset, length) {
        if (arguments.length !== 0 && arguments.length !== 1 && arguments.length !== 3) {
          throw new fail('Unsupported ByteArrayInputStream.read overload');
        }
        var data = ioState(this, 'Input');
        data.busy = true;
        try {
          if (arguments.length === 0) {
            if (data.position >= data.end) return -1;
            var source = ioInputSource(data);
            var byte = source.array ? ioArrayByte(source, data.position, false) : ioByte(source.items[data.position]);
            data.position += 1;
            return byte;
          }
          var destination = ioSource(output);
          var range = ioRange(destination, arguments.length === 1 ? 0 : offset, arguments.length === 1 ? destination.length : length);
          ioValidate(destination);
          // ByteArrayInputStream checks EOF before len == 0, unlike InputStream's default method.
          if (data.position >= data.end) return -1;
          var count = data.end - data.position;
          if (range.length < count) count = range.length;
          if (count === 0) return 0;
          var bytes = ioSnapshot(ioInputSource(data), data.position, count);
          // Snapshot first so overlapping source/destination ranges behave like System.arraycopy.
          ioStore(destination, range.offset, bytes, count);
          data.position += count;
          return count;
        } finally { data.busy = false; }
      });
      method(ioInputPrototype, 'available', function() {
        arity(arguments, 0, 0, 'ByteArrayInputStream.available');
        var data = ioState(this, 'Input');
        return data.end - data.position;
      });
      method(ioInputPrototype, 'skip', function(value) {
        arity(arguments, 1, 1, 'ByteArrayInputStream.skip');
        var data = ioState(this, 'Input');
        value = unbox(value);
        if (typeof value !== 'number' || !safeInteger(value)) throw new outOfBounds('ByteArrayInputStream.skip requires an exactly representable Java long');
        if (value <= 0) return 0;
        var count = data.end - data.position;
        if (value < count) count = value;
        data.position += count;
        return count;
      });
      method(ioInputPrototype, 'mark', function(readAheadLimit) {
        arity(arguments, 1, 1, 'ByteArrayInputStream.mark');
        var data = ioState(this, 'Input');
        ioInt(readAheadLimit, 'ByteArrayInputStream mark limit');
        data.mark = data.position;
      });
      method(ioInputPrototype, 'reset', function() {
        arity(arguments, 0, 0, 'ByteArrayInputStream.reset');
        var data = ioState(this, 'Input');
        data.position = data.mark;
      });
      method(ioInputPrototype, 'markSupported', function() {
        arity(arguments, 0, 0, 'ByteArrayInputStream.markSupported');
        ioState(this, 'Input');
        return true;
      });
      method(ioInputPrototype, 'close', function() {
        arity(arguments, 0, 0, 'ByteArrayInputStream.close');
        ioState(this, 'Input');
      });
      ByteArrayInputStream.prototype = ioInputPrototype;
      freeze(ioOutputPrototype); freeze(ioInputPrototype);
      JByteArrayOutputStream = freeze(ByteArrayOutputStream);
      JByteArrayInputStream = freeze(ByteArrayInputStream);
    })();
""".trimIndent()
