#
# BSD 3-Clause License
#
# Copyright (c) 2018 - 2026, Oleg Malyavkin
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# DEBUG_TAB redefine this "  " if you need, example: const DEBUG_TAB = "\t"

const PROTO_VERSION = 3

const DEBUG_TAB : String = "  "

enum PB_ERR {
	NO_ERRORS = 0,
	VARINT_NOT_FOUND = -1,
	REPEATED_COUNT_NOT_FOUND = -2,
	REPEATED_COUNT_MISMATCH = -3,
	LENGTHDEL_SIZE_NOT_FOUND = -4,
	LENGTHDEL_SIZE_MISMATCH = -5,
	PACKAGE_SIZE_MISMATCH = -6,
	UNDEFINED_STATE = -7,
	PARSE_INCOMPLETE = -8,
	REQUIRED_FIELDS = -9
}

enum PB_DATA_TYPE {
	INT32 = 0,
	SINT32 = 1,
	UINT32 = 2,
	INT64 = 3,
	SINT64 = 4,
	UINT64 = 5,
	BOOL = 6,
	ENUM = 7,
	FIXED32 = 8,
	SFIXED32 = 9,
	FLOAT = 10,
	FIXED64 = 11,
	SFIXED64 = 12,
	DOUBLE = 13,
	STRING = 14,
	BYTES = 15,
	MESSAGE = 16,
	MAP = 17
}

const DEFAULT_VALUES_2 = {
	PB_DATA_TYPE.INT32: null,
	PB_DATA_TYPE.SINT32: null,
	PB_DATA_TYPE.UINT32: null,
	PB_DATA_TYPE.INT64: null,
	PB_DATA_TYPE.SINT64: null,
	PB_DATA_TYPE.UINT64: null,
	PB_DATA_TYPE.BOOL: null,
	PB_DATA_TYPE.ENUM: null,
	PB_DATA_TYPE.FIXED32: null,
	PB_DATA_TYPE.SFIXED32: null,
	PB_DATA_TYPE.FLOAT: null,
	PB_DATA_TYPE.FIXED64: null,
	PB_DATA_TYPE.SFIXED64: null,
	PB_DATA_TYPE.DOUBLE: null,
	PB_DATA_TYPE.STRING: null,
	PB_DATA_TYPE.BYTES: null,
	PB_DATA_TYPE.MESSAGE: null,
	PB_DATA_TYPE.MAP: null
}

const DEFAULT_VALUES_3 = {
	PB_DATA_TYPE.INT32: 0,
	PB_DATA_TYPE.SINT32: 0,
	PB_DATA_TYPE.UINT32: 0,
	PB_DATA_TYPE.INT64: 0,
	PB_DATA_TYPE.SINT64: 0,
	PB_DATA_TYPE.UINT64: 0,
	PB_DATA_TYPE.BOOL: false,
	PB_DATA_TYPE.ENUM: 0,
	PB_DATA_TYPE.FIXED32: 0,
	PB_DATA_TYPE.SFIXED32: 0,
	PB_DATA_TYPE.FLOAT: 0.0,
	PB_DATA_TYPE.FIXED64: 0,
	PB_DATA_TYPE.SFIXED64: 0,
	PB_DATA_TYPE.DOUBLE: 0.0,
	PB_DATA_TYPE.STRING: "",
	PB_DATA_TYPE.BYTES: [],
	PB_DATA_TYPE.MESSAGE: null,
	PB_DATA_TYPE.MAP: []
}

enum PB_TYPE {
	VARINT = 0,
	FIX64 = 1,
	LENGTHDEL = 2,
	STARTGROUP = 3,
	ENDGROUP = 4,
	FIX32 = 5,
	UNDEFINED = 8
}

enum PB_RULE {
	OPTIONAL = 0,
	REQUIRED = 1,
	REPEATED = 2,
	RESERVED = 3
}

enum PB_SERVICE_STATE {
	FILLED = 0,
	UNFILLED = 1
}

class PBField:
	extends RefCounted
	func _init(a_name : String, a_type : int, a_rule : int, a_tag : int, packed : bool, a_value = null):
		name = a_name
		type = a_type
		rule = a_rule
		tag = a_tag
		option_packed = packed
		value = a_value
		
	var name : String
	var type : int
	var rule : int
	var tag : int
	var option_packed : bool
	var value
	var is_map_field : bool = false
	var option_default : bool = false

class PBTypeTag:
	extends RefCounted
	var ok : bool = false
	var type : int
	var tag : int
	var offset : int

class PBServiceField:
	extends RefCounted
	var field : PBField
	var func_ref = null
	var state : int = PB_SERVICE_STATE.UNFILLED

class PBPacker:
	static func convert_signed(n : int) -> int:
		if n < -2147483648:
			return (n << 1) ^ (n >> 63)
		else:
			return (n << 1) ^ (n >> 31)

	static func deconvert_signed(n : int) -> int:
		if n & 0x01:
			return ~(n >> 1)
		else:
			return (n >> 1)

	static func pack_varint(value) -> PackedByteArray:
		var varint : PackedByteArray = PackedByteArray()
		if typeof(value) == TYPE_BOOL:
			if value:
				value = 1
			else:
				value = 0
		for _i in range(9):
			var b = value & 0x7F
			value >>= 7
			if value:
				varint.append(b | 0x80)
			else:
				varint.append(b)
				break
		if varint.size() == 9 && (varint[8] & 0x80 != 0):
			varint.append(0x01)
		return varint

	static func pack_bytes(value, count : int, data_type : int) -> PackedByteArray:
		var bytes : PackedByteArray = PackedByteArray()
		if data_type == PB_DATA_TYPE.FLOAT:
			var spb : StreamPeerBuffer = StreamPeerBuffer.new()
			spb.put_float(value)
			bytes = spb.get_data_array()
		elif data_type == PB_DATA_TYPE.DOUBLE:
			var spb : StreamPeerBuffer = StreamPeerBuffer.new()
			spb.put_double(value)
			bytes = spb.get_data_array()
		else:
			for _i in range(count):
				bytes.append(value & 0xFF)
				value >>= 8
		return bytes

	static func unpack_bytes(bytes : PackedByteArray, index : int, count : int, data_type : int):
		if data_type == PB_DATA_TYPE.FLOAT:
			return bytes.decode_float(index)
		elif data_type == PB_DATA_TYPE.DOUBLE:
			return bytes.decode_double(index)
		elif data_type == PB_DATA_TYPE.FIXED32:
			return bytes.decode_u32(index)
		elif data_type == PB_DATA_TYPE.SFIXED32:
			return bytes.decode_s32(index)
		elif data_type == PB_DATA_TYPE.FIXED64:
			return bytes.decode_u64(index)
		elif data_type == PB_DATA_TYPE.SFIXED64:
			return bytes.decode_s64(index)
		else:
			var value : int = 0
			for i in range(count):
				value |= bytes[index + i] << (8 * i)
			return value

	static func unpack_varint(varint_bytes) -> int:
		var value : int = 0
		var i: int = varint_bytes.size() - 1
		while i > -1:
			value = (value << 7) | (varint_bytes[i] & 0x7F)
			i -= 1
		return value

	static func pack_type_tag(type : int, tag : int) -> PackedByteArray:
		return pack_varint((tag << 3) | type)

	static func isolate_varint(bytes : PackedByteArray, index : int) -> PackedByteArray:
		var i: int = index
		while i <= index + 10 && i < bytes.size(): # Protobuf varint max size is 10 bytes
			if !(bytes[i] & 0x80):
				return bytes.slice(index, i + 1)
			i += 1
		return [] # Unreachable

	static func unpack_type_tag(bytes : PackedByteArray, index : int) -> PBTypeTag:
		var varint_bytes : PackedByteArray = isolate_varint(bytes, index)
		var result : PBTypeTag = PBTypeTag.new()
		if varint_bytes.size() != 0:
			result.ok = true
			result.offset = varint_bytes.size()
			var unpacked : int = unpack_varint(varint_bytes)
			result.type = unpacked & 0x07
			result.tag = unpacked >> 3
		return result

	static func pack_length_delimeted(type : int, tag : int, bytes : PackedByteArray) -> PackedByteArray:
		var result : PackedByteArray = pack_type_tag(type, tag)
		result.append_array(pack_varint(bytes.size()))
		result.append_array(bytes)
		return result

	static func pb_type_from_data_type(data_type : int) -> int:
		if data_type == PB_DATA_TYPE.INT32 || data_type == PB_DATA_TYPE.SINT32 || data_type == PB_DATA_TYPE.UINT32 || data_type == PB_DATA_TYPE.INT64 || data_type == PB_DATA_TYPE.SINT64 || data_type == PB_DATA_TYPE.UINT64 || data_type == PB_DATA_TYPE.BOOL || data_type == PB_DATA_TYPE.ENUM:
			return PB_TYPE.VARINT
		elif data_type == PB_DATA_TYPE.FIXED32 || data_type == PB_DATA_TYPE.SFIXED32 || data_type == PB_DATA_TYPE.FLOAT:
			return PB_TYPE.FIX32
		elif data_type == PB_DATA_TYPE.FIXED64 || data_type == PB_DATA_TYPE.SFIXED64 || data_type == PB_DATA_TYPE.DOUBLE:
			return PB_TYPE.FIX64
		elif data_type == PB_DATA_TYPE.STRING || data_type == PB_DATA_TYPE.BYTES || data_type == PB_DATA_TYPE.MESSAGE || data_type == PB_DATA_TYPE.MAP:
			return PB_TYPE.LENGTHDEL
		else:
			return PB_TYPE.UNDEFINED

	static func pack_field(field : PBField) -> PackedByteArray:
		var type : int = pb_type_from_data_type(field.type)
		var type_copy : int = type
		if field.rule == PB_RULE.REPEATED && field.option_packed:
			type = PB_TYPE.LENGTHDEL
		var head : PackedByteArray = pack_type_tag(type, field.tag)
		var data : PackedByteArray = PackedByteArray()
		if type == PB_TYPE.VARINT:
			var value
			if field.rule == PB_RULE.REPEATED:
				for v in field.value:
					data.append_array(head)
					if field.type == PB_DATA_TYPE.SINT32 || field.type == PB_DATA_TYPE.SINT64:
						value = convert_signed(v)
					else:
						value = v
					data.append_array(pack_varint(value))
				return data
			else:
				if field.type == PB_DATA_TYPE.SINT32 || field.type == PB_DATA_TYPE.SINT64:
					value = convert_signed(field.value)
				else:
					value = field.value
				data = pack_varint(value)
		elif type == PB_TYPE.FIX32:
			if field.rule == PB_RULE.REPEATED:
				for v in field.value:
					data.append_array(head)
					data.append_array(pack_bytes(v, 4, field.type))
				return data
			else:
				data.append_array(pack_bytes(field.value, 4, field.type))
		elif type == PB_TYPE.FIX64:
			if field.rule == PB_RULE.REPEATED:
				for v in field.value:
					data.append_array(head)
					data.append_array(pack_bytes(v, 8, field.type))
				return data
			else:
				data.append_array(pack_bytes(field.value, 8, field.type))
		elif type == PB_TYPE.LENGTHDEL:
			if field.rule == PB_RULE.REPEATED:
				if type_copy == PB_TYPE.VARINT:
					if field.type == PB_DATA_TYPE.SINT32 || field.type == PB_DATA_TYPE.SINT64:
						var signed_value : int
						for v in field.value:
							signed_value = convert_signed(v)
							data.append_array(pack_varint(signed_value))
					else:
						for v in field.value:
							data.append_array(pack_varint(v))
					return pack_length_delimeted(type, field.tag, data)
				elif type_copy == PB_TYPE.FIX32:
					for v in field.value:
						data.append_array(pack_bytes(v, 4, field.type))
					return pack_length_delimeted(type, field.tag, data)
				elif type_copy == PB_TYPE.FIX64:
					for v in field.value:
						data.append_array(pack_bytes(v, 8, field.type))
					return pack_length_delimeted(type, field.tag, data)
				elif field.type == PB_DATA_TYPE.STRING:
					for v in field.value:
						var obj = v.to_utf8_buffer()
						data.append_array(pack_length_delimeted(type, field.tag, obj))
					return data
				elif field.type == PB_DATA_TYPE.BYTES:
					for v in field.value:
						data.append_array(pack_length_delimeted(type, field.tag, v))
					return data
				elif typeof(field.value[0]) == TYPE_OBJECT:
					for v in field.value:
						var obj : PackedByteArray = v.to_bytes()
						data.append_array(pack_length_delimeted(type, field.tag, obj))
					return data
			else:
				if field.type == PB_DATA_TYPE.STRING:
					var str_bytes : PackedByteArray = field.value.to_utf8_buffer()
					if PROTO_VERSION == 2 || (PROTO_VERSION == 3 && str_bytes.size() > 0):
						data.append_array(str_bytes)
						return pack_length_delimeted(type, field.tag, data)
				if field.type == PB_DATA_TYPE.BYTES:
					if PROTO_VERSION == 2 || (PROTO_VERSION == 3 && field.value.size() > 0):
						data.append_array(field.value)
						return pack_length_delimeted(type, field.tag, data)
				elif typeof(field.value) == TYPE_OBJECT:
					var obj : PackedByteArray = field.value.to_bytes()
					if obj.size() > 0:
						data.append_array(obj)
					return pack_length_delimeted(type, field.tag, data)
				else:
					pass
		if data.size() > 0:
			head.append_array(data)
			return head
		else:
			return data

	static func skip_unknown_field(bytes : PackedByteArray, offset : int, type : int) -> int:
		if type == PB_TYPE.VARINT:
			return offset + isolate_varint(bytes, offset).size()
		if type == PB_TYPE.FIX64:
			return offset + 8
		if type == PB_TYPE.LENGTHDEL:
			var length_bytes : PackedByteArray = isolate_varint(bytes, offset)
			var length : int = unpack_varint(length_bytes)
			return offset + length_bytes.size() + length
		if type == PB_TYPE.FIX32:
			return offset + 4
		return PB_ERR.UNDEFINED_STATE

	static func unpack_field(bytes : PackedByteArray, offset : int, field : PBField, type : int, message_func_ref) -> int:
		if field.rule == PB_RULE.REPEATED && type != PB_TYPE.LENGTHDEL && field.option_packed:
			var count = isolate_varint(bytes, offset)
			if count.size() > 0:
				offset += count.size()
				count = unpack_varint(count)
				if type == PB_TYPE.VARINT:
					var val
					var counter = offset + count
					while offset < counter:
						val = isolate_varint(bytes, offset)
						if val.size() > 0:
							offset += val.size()
							val = unpack_varint(val)
							if field.type == PB_DATA_TYPE.SINT32 || field.type == PB_DATA_TYPE.SINT64:
								val = deconvert_signed(val)
							elif field.type == PB_DATA_TYPE.BOOL:
								if val:
									val = true
								else:
									val = false
							field.value.append(val)
						else:
							return PB_ERR.REPEATED_COUNT_MISMATCH
					return offset
				elif type == PB_TYPE.FIX32 || type == PB_TYPE.FIX64:
					var type_size
					if type == PB_TYPE.FIX32:
						type_size = 4
					else:
						type_size = 8
					var val
					var counter = offset + count
					while offset < counter:
						if (offset + type_size) > bytes.size():
							return PB_ERR.REPEATED_COUNT_MISMATCH
						val = unpack_bytes(bytes, offset, type_size, field.type)
						offset += type_size
						field.value.append(val)
					return offset
			else:
				return PB_ERR.REPEATED_COUNT_NOT_FOUND
		else:
			if type == PB_TYPE.VARINT:
				var val = isolate_varint(bytes, offset)
				if val.size() > 0:
					offset += val.size()
					val = unpack_varint(val)
					if field.type == PB_DATA_TYPE.SINT32 || field.type == PB_DATA_TYPE.SINT64:
						val = deconvert_signed(val)
					elif field.type == PB_DATA_TYPE.BOOL:
						if val:
							val = true
						else:
							val = false
					if field.rule == PB_RULE.REPEATED:
						field.value.append(val)
					else:
						field.value = val
				else:
					return PB_ERR.VARINT_NOT_FOUND
				return offset
			elif type == PB_TYPE.FIX32 || type == PB_TYPE.FIX64:
				var type_size
				if type == PB_TYPE.FIX32:
					type_size = 4
				else:
					type_size = 8
				var val
				if (offset + type_size) > bytes.size():
					return PB_ERR.REPEATED_COUNT_MISMATCH
				val = unpack_bytes(bytes, offset, type_size, field.type)
				offset += type_size
				if field.rule == PB_RULE.REPEATED:
					field.value.append(val)
				else:
					field.value = val
				return offset
			elif type == PB_TYPE.LENGTHDEL:
				var inner_size = isolate_varint(bytes, offset)
				if inner_size.size() > 0:
					offset += inner_size.size()
					inner_size = unpack_varint(inner_size)
					if inner_size >= 0:
						if inner_size + offset > bytes.size():
							return PB_ERR.LENGTHDEL_SIZE_MISMATCH
						if message_func_ref != null:
							var message = message_func_ref.call()
							if inner_size > 0:
								var sub_offset = message.from_bytes(bytes, offset, inner_size + offset)
								if sub_offset > 0:
									if sub_offset - offset >= inner_size:
										offset = sub_offset
										return offset
									else:
										return PB_ERR.LENGTHDEL_SIZE_MISMATCH
								return sub_offset
							else:
								return offset
						elif field.type == PB_DATA_TYPE.STRING:
							var str_bytes : PackedByteArray = bytes.slice(offset, inner_size + offset)
							if field.rule == PB_RULE.REPEATED:
								field.value.append(str_bytes.get_string_from_utf8())
							else:
								field.value = str_bytes.get_string_from_utf8()
							return offset + inner_size
						elif field.type == PB_DATA_TYPE.BYTES:
							var val_bytes : PackedByteArray = bytes.slice(offset, inner_size + offset)
							if field.rule == PB_RULE.REPEATED:
								field.value.append(val_bytes)
							else:
								field.value = val_bytes
							return offset + inner_size
					else:
						return PB_ERR.LENGTHDEL_SIZE_NOT_FOUND
				else:
					return PB_ERR.LENGTHDEL_SIZE_NOT_FOUND
		return PB_ERR.UNDEFINED_STATE

	static func unpack_message(data, bytes : PackedByteArray, offset : int, limit : int) -> int:
		while true:
			var tt : PBTypeTag = unpack_type_tag(bytes, offset)
			if tt.ok:
				offset += tt.offset
				if data.has(tt.tag):
					var service : PBServiceField = data[tt.tag]
					var type : int = pb_type_from_data_type(service.field.type)
					if type == tt.type || (tt.type == PB_TYPE.LENGTHDEL && service.field.rule == PB_RULE.REPEATED && service.field.option_packed):
						var res : int = unpack_field(bytes, offset, service.field, type, service.func_ref)
						if res > 0:
							service.state = PB_SERVICE_STATE.FILLED
							offset = res
							if offset == limit:
								return offset
							elif offset > limit:
								return PB_ERR.PACKAGE_SIZE_MISMATCH
						elif res < 0:
							return res
						else:
							break
				else:
					var res : int = skip_unknown_field(bytes, offset, tt.type)
					if res > 0:
						offset = res
						if offset == limit:
							return offset
						elif offset > limit:
							return PB_ERR.PACKAGE_SIZE_MISMATCH
					elif res < 0:
						return res
					else:
						break							
			else:
				return offset
		return PB_ERR.UNDEFINED_STATE

	static func pack_message(data) -> PackedByteArray:
		var DEFAULT_VALUES
		if PROTO_VERSION == 2:
			DEFAULT_VALUES = DEFAULT_VALUES_2
		elif PROTO_VERSION == 3:
			DEFAULT_VALUES = DEFAULT_VALUES_3
		var result : PackedByteArray = PackedByteArray()
		var keys : Array = data.keys()
		keys.sort()
		for i in keys:
			if data[i].field.value != null:
				if data[i].state == PB_SERVICE_STATE.UNFILLED \
				&& !data[i].field.is_map_field \
				&& typeof(data[i].field.value) == typeof(DEFAULT_VALUES[data[i].field.type]) \
				&& data[i].field.value == DEFAULT_VALUES[data[i].field.type]:
					continue
				elif data[i].field.rule == PB_RULE.REPEATED && data[i].field.value.size() == 0:
					continue
				result.append_array(pack_field(data[i].field))
			elif data[i].field.rule == PB_RULE.REQUIRED:
				print("Error: required field is not filled: Tag:", data[i].field.tag)
				return PackedByteArray()
		return result

	static func check_required(data) -> bool:
		var keys : Array = data.keys()
		for i in keys:
			if data[i].field.rule == PB_RULE.REQUIRED && data[i].state == PB_SERVICE_STATE.UNFILLED:
				return false
		return true

	static func construct_map(key_values):
		var result = {}
		for kv in key_values:
			result[kv.get_key()] = kv.get_value()
		return result
	
	static func tabulate(text : String, nesting : int) -> String:
		var tab : String = ""
		for _i in range(nesting):
			tab += DEBUG_TAB
		return tab + text
	
	static func value_to_string(value, field : PBField, nesting : int) -> String:
		var result : String = ""
		var text : String
		if field.type == PB_DATA_TYPE.MESSAGE:
			result += "{"
			nesting += 1
			text = message_to_string(value.data, nesting)
			if text != "":
				result += "\n" + text
				nesting -= 1
				result += tabulate("}", nesting)
			else:
				nesting -= 1
				result += "}"
		elif field.type == PB_DATA_TYPE.BYTES:
			result += "<"
			for i in range(value.size()):
				result += str(value[i])
				if i != (value.size() - 1):
					result += ", "
			result += ">"
		elif field.type == PB_DATA_TYPE.STRING:
			result += "\"" + value + "\""
		elif field.type == PB_DATA_TYPE.ENUM:
			result += "ENUM::" + str(value)
		else:
			result += str(value)
		return result
	
	static func field_to_string(field : PBField, nesting : int) -> String:
		var result : String = tabulate(field.name + ": ", nesting)
		if field.type == PB_DATA_TYPE.MAP:
			if field.value.size() > 0:
				result += "(\n"
				nesting += 1
				for i in range(field.value.size()):
					var local_key_value = field.value[i].data[1].field
					result += tabulate(value_to_string(local_key_value.value, local_key_value, nesting), nesting) + ": "
					local_key_value = field.value[i].data[2].field
					result += value_to_string(local_key_value.value, local_key_value, nesting)
					if i != (field.value.size() - 1):
						result += ","
					result += "\n"
				nesting -= 1
				result += tabulate(")", nesting)
			else:
				result += "()"
		elif field.rule == PB_RULE.REPEATED:
			if field.value.size() > 0:
				result += "[\n"
				nesting += 1
				for i in range(field.value.size()):
					result += tabulate(str(i) + ": ", nesting)
					result += value_to_string(field.value[i], field, nesting)
					if i != (field.value.size() - 1):
						result += ","
					result += "\n"
				nesting -= 1
				result += tabulate("]", nesting)
			else:
				result += "[]"
		else:
			result += value_to_string(field.value, field, nesting)
		result += ";\n"
		return result
		
	static func message_to_string(data, nesting : int = 0) -> String:
		var DEFAULT_VALUES
		if PROTO_VERSION == 2:
			DEFAULT_VALUES = DEFAULT_VALUES_2
		elif PROTO_VERSION == 3:
			DEFAULT_VALUES = DEFAULT_VALUES_3
		var result : String = ""
		var keys : Array = data.keys()
		keys.sort()
		for i in keys:
			if data[i].field.value != null:
				if data[i].state == PB_SERVICE_STATE.UNFILLED \
				&& !data[i].field.is_map_field \
				&& typeof(data[i].field.value) == typeof(DEFAULT_VALUES[data[i].field.type]) \
				&& data[i].field.value == DEFAULT_VALUES[data[i].field.type]:
					continue
				elif data[i].field.rule == PB_RULE.REPEATED && data[i].field.value.size() == 0:
					continue
				result += field_to_string(data[i].field, nesting)
			elif data[i].field.rule == PB_RULE.REQUIRED:
				result += data[i].field.name + ": " + "error"
		return result



############### USER DATA BEGIN ################


class EntityInfo:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__entity_type = PBField.new("entity_type", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_type
		data[__entity_type.tag] = service
		
		__x = PBField.new("x", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __x
		data[__x.tag] = service
		
		__y = PBField.new("y", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __y
		data[__y.tag] = service
		
		__facing = PBField.new("facing", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 5, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __facing
		data[__facing.tag] = service
		
		__state = PBField.new("state", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 6, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __state
		data[__state.tag] = service
		
		__player_name = PBField.new("player_name", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 8, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __player_name
		data[__player_name.tag] = service
		
		__moving = PBField.new("moving", PB_DATA_TYPE.BOOL, PB_RULE.OPTIONAL, 9, true, DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL])
		service = PBServiceField.new()
		service.field = __moving
		data[__moving.tag] = service
		
		__account_id = PBField.new("account_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 10, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __account_id
		data[__account_id.tag] = service
		
		__ai_state = PBField.new("ai_state", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 11, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __ai_state
		data[__ai_state.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __entity_type: PBField
	func has_entity_type() -> bool:
		if __entity_type.value != null:
			return true
		return false
	func get_entity_type() -> String:
		return __entity_type.value
	func clear_entity_type() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__entity_type.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_type(value : String) -> void:
		__entity_type.value = value
	
	var __x: PBField
	func has_x() -> bool:
		if __x.value != null:
			return true
		return false
	func get_x() -> float:
		return __x.value
	func clear_x() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__x.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_x(value : float) -> void:
		__x.value = value
	
	var __y: PBField
	func has_y() -> bool:
		if __y.value != null:
			return true
		return false
	func get_y() -> float:
		return __y.value
	func clear_y() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__y.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_y(value : float) -> void:
		__y.value = value
	
	var __facing: PBField
	func has_facing() -> bool:
		if __facing.value != null:
			return true
		return false
	func get_facing() -> float:
		return __facing.value
	func clear_facing() -> void:
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_facing(value : float) -> void:
		__facing.value = value
	
	var __state: PBField
	func has_state() -> bool:
		if __state.value != null:
			return true
		return false
	func get_state() -> String:
		return __state.value
	func clear_state() -> void:
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_state(value : String) -> void:
		__state.value = value
	
	var __player_name: PBField
	func has_player_name() -> bool:
		if __player_name.value != null:
			return true
		return false
	func get_player_name() -> String:
		return __player_name.value
	func clear_player_name() -> void:
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__player_name.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_player_name(value : String) -> void:
		__player_name.value = value
	
	var __moving: PBField
	func has_moving() -> bool:
		if __moving.value != null:
			return true
		return false
	func get_moving() -> bool:
		return __moving.value
	func clear_moving() -> void:
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__moving.value = DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL]
	func set_moving(value : bool) -> void:
		__moving.value = value
	
	var __account_id: PBField
	func has_account_id() -> bool:
		if __account_id.value != null:
			return true
		return false
	func get_account_id() -> String:
		return __account_id.value
	func clear_account_id() -> void:
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__account_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_account_id(value : String) -> void:
		__account_id.value = value
	
	var __ai_state: PBField
	func has_ai_state() -> bool:
		if __ai_state.value != null:
			return true
		return false
	func get_ai_state() -> String:
		return __ai_state.value
	func clear_ai_state() -> void:
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__ai_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_ai_state(value : String) -> void:
		__ai_state.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class ChatMessage:
	extends RefCounted
	func _init():
		var service
		
		__player_id = PBField.new("player_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __player_id
		data[__player_id.tag] = service
		
		__player_name = PBField.new("player_name", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __player_name
		data[__player_name.tag] = service
		
		__content = PBField.new("content", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __content
		data[__content.tag] = service
		
		__timestamp = PBField.new("timestamp", PB_DATA_TYPE.INT64, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT64])
		service = PBServiceField.new()
		service.field = __timestamp
		data[__timestamp.tag] = service
		
	var data = {}
	
	var __player_id: PBField
	func has_player_id() -> bool:
		if __player_id.value != null:
			return true
		return false
	func get_player_id() -> String:
		return __player_id.value
	func clear_player_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__player_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_player_id(value : String) -> void:
		__player_id.value = value
	
	var __player_name: PBField
	func has_player_name() -> bool:
		if __player_name.value != null:
			return true
		return false
	func get_player_name() -> String:
		return __player_name.value
	func clear_player_name() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_name.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_player_name(value : String) -> void:
		__player_name.value = value
	
	var __content: PBField
	func has_content() -> bool:
		if __content.value != null:
			return true
		return false
	func get_content() -> String:
		return __content.value
	func clear_content() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__content.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_content(value : String) -> void:
		__content.value = value
	
	var __timestamp: PBField
	func has_timestamp() -> bool:
		if __timestamp.value != null:
			return true
		return false
	func get_timestamp() -> int:
		return __timestamp.value
	func clear_timestamp() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__timestamp.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT64]
	func set_timestamp(value : int) -> void:
		__timestamp.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class PlayerMove:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__x = PBField.new("x", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __x
		data[__x.tag] = service
		
		__y = PBField.new("y", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __y
		data[__y.tag] = service
		
		__speed = PBField.new("speed", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __speed
		data[__speed.tag] = service
		
		__moving = PBField.new("moving", PB_DATA_TYPE.BOOL, PB_RULE.OPTIONAL, 5, true, DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL])
		service = PBServiceField.new()
		service.field = __moving
		data[__moving.tag] = service
		
		__dir_x = PBField.new("dir_x", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 6, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __dir_x
		data[__dir_x.tag] = service
		
		__dir_y = PBField.new("dir_y", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 7, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __dir_y
		data[__dir_y.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __x: PBField
	func has_x() -> bool:
		if __x.value != null:
			return true
		return false
	func get_x() -> float:
		return __x.value
	func clear_x() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__x.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_x(value : float) -> void:
		__x.value = value
	
	var __y: PBField
	func has_y() -> bool:
		if __y.value != null:
			return true
		return false
	func get_y() -> float:
		return __y.value
	func clear_y() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__y.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_y(value : float) -> void:
		__y.value = value
	
	var __speed: PBField
	func has_speed() -> bool:
		if __speed.value != null:
			return true
		return false
	func get_speed() -> float:
		return __speed.value
	func clear_speed() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__speed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_speed(value : float) -> void:
		__speed.value = value
	
	var __moving: PBField
	func has_moving() -> bool:
		if __moving.value != null:
			return true
		return false
	func get_moving() -> bool:
		return __moving.value
	func clear_moving() -> void:
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__moving.value = DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL]
	func set_moving(value : bool) -> void:
		__moving.value = value
	
	var __dir_x: PBField
	func has_dir_x() -> bool:
		if __dir_x.value != null:
			return true
		return false
	func get_dir_x() -> float:
		return __dir_x.value
	func clear_dir_x() -> void:
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__dir_x.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_dir_x(value : float) -> void:
		__dir_x.value = value
	
	var __dir_y: PBField
	func has_dir_y() -> bool:
		if __dir_y.value != null:
			return true
		return false
	func get_dir_y() -> float:
		return __dir_y.value
	func clear_dir_y() -> void:
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__dir_y.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_dir_y(value : float) -> void:
		__dir_y.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class PlayerFacing:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__facing = PBField.new("facing", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __facing
		data[__facing.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __facing: PBField
	func has_facing() -> bool:
		if __facing.value != null:
			return true
		return false
	func get_facing() -> float:
		return __facing.value
	func clear_facing() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_facing(value : float) -> void:
		__facing.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class Login:
	extends RefCounted
	func _init():
		var service
		
		__account_id = PBField.new("account_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __account_id
		data[__account_id.tag] = service
		
		__player_name = PBField.new("player_name", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __player_name
		data[__player_name.tag] = service
		
	var data = {}
	
	var __account_id: PBField
	func has_account_id() -> bool:
		if __account_id.value != null:
			return true
		return false
	func get_account_id() -> String:
		return __account_id.value
	func clear_account_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__account_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_account_id(value : String) -> void:
		__account_id.value = value
	
	var __player_name: PBField
	func has_player_name() -> bool:
		if __player_name.value != null:
			return true
		return false
	func get_player_name() -> String:
		return __player_name.value
	func clear_player_name() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_name.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_player_name(value : String) -> void:
		__player_name.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class EnterRoom:
	extends RefCounted
	func _init():
		var service
		
		__entity_info = PBField.new("entity_info", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __entity_info
		service.func_ref = Callable(self, "new_entity_info")
		data[__entity_info.tag] = service
		
	var data = {}
	
	var __entity_info: PBField
	func has_entity_info() -> bool:
		if __entity_info.value != null:
			return true
		return false
	func get_entity_info() -> EntityInfo:
		return __entity_info.value
	func clear_entity_info() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_entity_info() -> EntityInfo:
		__entity_info.value = EntityInfo.new()
		return __entity_info.value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class LeaveRoom:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class AttackStart:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__atk_id = PBField.new("atk_id", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __atk_id
		data[__atk_id.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __atk_id: PBField
	func has_atk_id() -> bool:
		if __atk_id.value != null:
			return true
		return false
	func get_atk_id() -> int:
		return __atk_id.value
	func clear_atk_id() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__atk_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_atk_id(value : int) -> void:
		__atk_id.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class AttackHit:
	extends RefCounted
	func _init():
		var service
		
		__attacker_id = PBField.new("attacker_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __attacker_id
		data[__attacker_id.tag] = service
		
		var __hit_list_default: Array[String] = []
		__hit_list = PBField.new("hit_list", PB_DATA_TYPE.STRING, PB_RULE.REPEATED, 2, true, __hit_list_default)
		service = PBServiceField.new()
		service.field = __hit_list
		data[__hit_list.tag] = service
		
		__atk_id = PBField.new("atk_id", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __atk_id
		data[__atk_id.tag] = service
		
		__hurt_duration = PBField.new("hurt_duration", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __hurt_duration
		data[__hurt_duration.tag] = service
		
		__atk_shape_idx = PBField.new("atk_shape_idx", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 5, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __atk_shape_idx
		data[__atk_shape_idx.tag] = service
		
	var data = {}
	
	var __attacker_id: PBField
	func has_attacker_id() -> bool:
		if __attacker_id.value != null:
			return true
		return false
	func get_attacker_id() -> String:
		return __attacker_id.value
	func clear_attacker_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__attacker_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_attacker_id(value : String) -> void:
		__attacker_id.value = value
	
	var __hit_list: PBField
	func get_hit_list() -> Array[String]:
		return __hit_list.value
	func clear_hit_list() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__hit_list.value.clear()
	func add_hit_list(value : String) -> void:
		__hit_list.value.append(value)
	
	var __atk_id: PBField
	func has_atk_id() -> bool:
		if __atk_id.value != null:
			return true
		return false
	func get_atk_id() -> int:
		return __atk_id.value
	func clear_atk_id() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__atk_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_atk_id(value : int) -> void:
		__atk_id.value = value
	
	var __hurt_duration: PBField
	func has_hurt_duration() -> bool:
		if __hurt_duration.value != null:
			return true
		return false
	func get_hurt_duration() -> int:
		return __hurt_duration.value
	func clear_hurt_duration() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__hurt_duration.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_hurt_duration(value : int) -> void:
		__hurt_duration.value = value
	
	var __atk_shape_idx: PBField
	func has_atk_shape_idx() -> bool:
		if __atk_shape_idx.value != null:
			return true
		return false
	func get_atk_shape_idx() -> int:
		return __atk_shape_idx.value
	func clear_atk_shape_idx() -> void:
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__atk_shape_idx.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_atk_shape_idx(value : int) -> void:
		__atk_shape_idx.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class HurtEnd:
	extends RefCounted
	func _init():
		var service
		
		__attacker_id = PBField.new("attacker_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __attacker_id
		data[__attacker_id.tag] = service
		
		__hurt_id = PBField.new("hurt_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __hurt_id
		data[__hurt_id.tag] = service
		
		__atk_id = PBField.new("atk_id", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __atk_id
		data[__atk_id.tag] = service
		
		__hurt_duration = PBField.new("hurt_duration", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __hurt_duration
		data[__hurt_duration.tag] = service
		
	var data = {}
	
	var __attacker_id: PBField
	func has_attacker_id() -> bool:
		if __attacker_id.value != null:
			return true
		return false
	func get_attacker_id() -> String:
		return __attacker_id.value
	func clear_attacker_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__attacker_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_attacker_id(value : String) -> void:
		__attacker_id.value = value
	
	var __hurt_id: PBField
	func has_hurt_id() -> bool:
		if __hurt_id.value != null:
			return true
		return false
	func get_hurt_id() -> String:
		return __hurt_id.value
	func clear_hurt_id() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__hurt_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_hurt_id(value : String) -> void:
		__hurt_id.value = value
	
	var __atk_id: PBField
	func has_atk_id() -> bool:
		if __atk_id.value != null:
			return true
		return false
	func get_atk_id() -> int:
		return __atk_id.value
	func clear_atk_id() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__atk_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_atk_id(value : int) -> void:
		__atk_id.value = value
	
	var __hurt_duration: PBField
	func has_hurt_duration() -> bool:
		if __hurt_duration.value != null:
			return true
		return false
	func get_hurt_duration() -> int:
		return __hurt_duration.value
	func clear_hurt_duration() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__hurt_duration.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_hurt_duration(value : int) -> void:
		__hurt_duration.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class AttackEnd:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class GameState:
	extends RefCounted
	func _init():
		var service
		
		var __entities_default: Array[EntityInfo] = []
		__entities = PBField.new("entities", PB_DATA_TYPE.MESSAGE, PB_RULE.REPEATED, 1, true, __entities_default)
		service = PBServiceField.new()
		service.field = __entities
		service.func_ref = Callable(self, "add_entities")
		data[__entities.tag] = service
		
		__timestamp = PBField.new("timestamp", PB_DATA_TYPE.INT64, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT64])
		service = PBServiceField.new()
		service.field = __timestamp
		data[__timestamp.tag] = service
		
	var data = {}
	
	var __entities: PBField
	func get_entities() -> Array[EntityInfo]:
		return __entities.value
	func clear_entities() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entities.value.clear()
	func add_entities() -> EntityInfo:
		var element = EntityInfo.new()
		__entities.value.append(element)
		return element
	
	var __timestamp: PBField
	func has_timestamp() -> bool:
		if __timestamp.value != null:
			return true
		return false
	func get_timestamp() -> int:
		return __timestamp.value
	func clear_timestamp() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__timestamp.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT64]
	func set_timestamp(value : int) -> void:
		__timestamp.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class Heartbeat:
	extends RefCounted
	func _init():
		var service
		
		__timestamp = PBField.new("timestamp", PB_DATA_TYPE.INT64, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT64])
		service = PBServiceField.new()
		service.field = __timestamp
		data[__timestamp.tag] = service
		
	var data = {}
	
	var __timestamp: PBField
	func has_timestamp() -> bool:
		if __timestamp.value != null:
			return true
		return false
	func get_timestamp() -> int:
		return __timestamp.value
	func clear_timestamp() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__timestamp.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT64]
	func set_timestamp(value : int) -> void:
		__timestamp.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class CombatStatsEntry:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__max_hp = PBField.new("max_hp", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __max_hp
		data[__max_hp.tag] = service
		
		__cur_hp = PBField.new("cur_hp", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __cur_hp
		data[__cur_hp.tag] = service
		
		__attack_power = PBField.new("attack_power", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __attack_power
		data[__attack_power.tag] = service
		
		__defense = PBField.new("defense", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 5, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __defense
		data[__defense.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __max_hp: PBField
	func has_max_hp() -> bool:
		if __max_hp.value != null:
			return true
		return false
	func get_max_hp() -> int:
		return __max_hp.value
	func clear_max_hp() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__max_hp.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_max_hp(value : int) -> void:
		__max_hp.value = value
	
	var __cur_hp: PBField
	func has_cur_hp() -> bool:
		if __cur_hp.value != null:
			return true
		return false
	func get_cur_hp() -> int:
		return __cur_hp.value
	func clear_cur_hp() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__cur_hp.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_cur_hp(value : int) -> void:
		__cur_hp.value = value
	
	var __attack_power: PBField
	func has_attack_power() -> bool:
		if __attack_power.value != null:
			return true
		return false
	func get_attack_power() -> int:
		return __attack_power.value
	func clear_attack_power() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__attack_power.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_attack_power(value : int) -> void:
		__attack_power.value = value
	
	var __defense: PBField
	func has_defense() -> bool:
		if __defense.value != null:
			return true
		return false
	func get_defense() -> int:
		return __defense.value
	func clear_defense() -> void:
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__defense.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_defense(value : int) -> void:
		__defense.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class StatsInit:
	extends RefCounted
	func _init():
		var service
		
		var __entries_default: Array[CombatStatsEntry] = []
		__entries = PBField.new("entries", PB_DATA_TYPE.MESSAGE, PB_RULE.REPEATED, 1, true, __entries_default)
		service = PBServiceField.new()
		service.field = __entries
		service.func_ref = Callable(self, "add_entries")
		data[__entries.tag] = service
		
	var data = {}
	
	var __entries: PBField
	func get_entries() -> Array[CombatStatsEntry]:
		return __entries.value
	func clear_entries() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entries.value.clear()
	func add_entries() -> CombatStatsEntry:
		var element = CombatStatsEntry.new()
		__entries.value.append(element)
		return element
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class StatsChanged:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__max_hp = PBField.new("max_hp", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __max_hp
		data[__max_hp.tag] = service
		
		__attack_power = PBField.new("attack_power", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __attack_power
		data[__attack_power.tag] = service
		
		__defense = PBField.new("defense", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __defense
		data[__defense.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __max_hp: PBField
	func has_max_hp() -> bool:
		if __max_hp.value != null:
			return true
		return false
	func get_max_hp() -> int:
		return __max_hp.value
	func clear_max_hp() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__max_hp.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_max_hp(value : int) -> void:
		__max_hp.value = value
	
	var __attack_power: PBField
	func has_attack_power() -> bool:
		if __attack_power.value != null:
			return true
		return false
	func get_attack_power() -> int:
		return __attack_power.value
	func clear_attack_power() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__attack_power.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_attack_power(value : int) -> void:
		__attack_power.value = value
	
	var __defense: PBField
	func has_defense() -> bool:
		if __defense.value != null:
			return true
		return false
	func get_defense() -> int:
		return __defense.value
	func clear_defense() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__defense.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_defense(value : int) -> void:
		__defense.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class HpChanged:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__cur_hp = PBField.new("cur_hp", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __cur_hp
		data[__cur_hp.tag] = service
		
		__damage = PBField.new("damage", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __damage
		data[__damage.tag] = service
		
		__attacker_id = PBField.new("attacker_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __attacker_id
		data[__attacker_id.tag] = service
		
		__atk_id = PBField.new("atk_id", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 5, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __atk_id
		data[__atk_id.tag] = service
		
		__atk_shape_idx = PBField.new("atk_shape_idx", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 6, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __atk_shape_idx
		data[__atk_shape_idx.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __cur_hp: PBField
	func has_cur_hp() -> bool:
		if __cur_hp.value != null:
			return true
		return false
	func get_cur_hp() -> int:
		return __cur_hp.value
	func clear_cur_hp() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__cur_hp.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_cur_hp(value : int) -> void:
		__cur_hp.value = value
	
	var __damage: PBField
	func has_damage() -> bool:
		if __damage.value != null:
			return true
		return false
	func get_damage() -> int:
		return __damage.value
	func clear_damage() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__damage.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_damage(value : int) -> void:
		__damage.value = value
	
	var __attacker_id: PBField
	func has_attacker_id() -> bool:
		if __attacker_id.value != null:
			return true
		return false
	func get_attacker_id() -> String:
		return __attacker_id.value
	func clear_attacker_id() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__attacker_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_attacker_id(value : String) -> void:
		__attacker_id.value = value
	
	var __atk_id: PBField
	func has_atk_id() -> bool:
		if __atk_id.value != null:
			return true
		return false
	func get_atk_id() -> int:
		return __atk_id.value
	func clear_atk_id() -> void:
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__atk_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_atk_id(value : int) -> void:
		__atk_id.value = value
	
	var __atk_shape_idx: PBField
	func has_atk_shape_idx() -> bool:
		if __atk_shape_idx.value != null:
			return true
		return false
	func get_atk_shape_idx() -> int:
		return __atk_shape_idx.value
	func clear_atk_shape_idx() -> void:
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__atk_shape_idx.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_atk_shape_idx(value : int) -> void:
		__atk_shape_idx.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class EntityDead:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__attacker_id = PBField.new("attacker_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __attacker_id
		data[__attacker_id.tag] = service
		
		__atk_id = PBField.new("atk_id", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __atk_id
		data[__atk_id.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __attacker_id: PBField
	func has_attacker_id() -> bool:
		if __attacker_id.value != null:
			return true
		return false
	func get_attacker_id() -> String:
		return __attacker_id.value
	func clear_attacker_id() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__attacker_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_attacker_id(value : String) -> void:
		__attacker_id.value = value
	
	var __atk_id: PBField
	func has_atk_id() -> bool:
		if __atk_id.value != null:
			return true
		return false
	func get_atk_id() -> int:
		return __atk_id.value
	func clear_atk_id() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__atk_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_atk_id(value : int) -> void:
		__atk_id.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class EntityRemove:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class Ping:
	extends RefCounted
	func _init():
		var service
		
		__t = PBField.new("t", PB_DATA_TYPE.INT64, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT64])
		service = PBServiceField.new()
		service.field = __t
		data[__t.tag] = service
		
	var data = {}
	
	var __t: PBField
	func has_t() -> bool:
		if __t.value != null:
			return true
		return false
	func get_t() -> int:
		return __t.value
	func clear_t() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__t.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT64]
	func set_t(value : int) -> void:
		__t.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class Pong:
	extends RefCounted
	func _init():
		var service
		
		__t = PBField.new("t", PB_DATA_TYPE.INT64, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT64])
		service = PBServiceField.new()
		service.field = __t
		data[__t.tag] = service
		
	var data = {}
	
	var __t: PBField
	func has_t() -> bool:
		if __t.value != null:
			return true
		return false
	func get_t() -> int:
		return __t.value
	func clear_t() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__t.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT64]
	func set_t(value : int) -> void:
		__t.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class MapInfo:
	extends RefCounted
	func _init():
		var service
		
		__seed = PBField.new("seed", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __seed
		data[__seed.tag] = service
		
	var data = {}
	
	var __seed: PBField
	func has_seed() -> bool:
		if __seed.value != null:
			return true
		return false
	func get_seed() -> int:
		return __seed.value
	func clear_seed() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__seed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_seed(value : int) -> void:
		__seed.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class AiStateChanged:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__ai_state = PBField.new("ai_state", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __ai_state
		data[__ai_state.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __ai_state: PBField
	func has_ai_state() -> bool:
		if __ai_state.value != null:
			return true
		return false
	func get_ai_state() -> String:
		return __ai_state.value
	func clear_ai_state() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__ai_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_ai_state(value : String) -> void:
		__ai_state.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class SurvivalState:
	extends RefCounted
	func _init():
		var service
		
		__elapsed_seconds = PBField.new("elapsed_seconds", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __elapsed_seconds
		data[__elapsed_seconds.tag] = service
		
		__wave = PBField.new("wave", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __wave
		data[__wave.tag] = service
		
		__paused = PBField.new("paused", PB_DATA_TYPE.BOOL, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL])
		service = PBServiceField.new()
		service.field = __paused
		data[__paused.tag] = service
		
		__level = PBField.new("level", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __level
		data[__level.tag] = service
		
		__experience = PBField.new("experience", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 5, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __experience
		data[__experience.tag] = service
		
		__next_experience = PBField.new("next_experience", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 6, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __next_experience
		data[__next_experience.tag] = service
		
	var data = {}
	
	var __elapsed_seconds: PBField
	func has_elapsed_seconds() -> bool:
		if __elapsed_seconds.value != null:
			return true
		return false
	func get_elapsed_seconds() -> float:
		return __elapsed_seconds.value
	func clear_elapsed_seconds() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__elapsed_seconds.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_elapsed_seconds(value : float) -> void:
		__elapsed_seconds.value = value
	
	var __wave: PBField
	func has_wave() -> bool:
		if __wave.value != null:
			return true
		return false
	func get_wave() -> int:
		return __wave.value
	func clear_wave() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__wave.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_wave(value : int) -> void:
		__wave.value = value
	
	var __paused: PBField
	func has_paused() -> bool:
		if __paused.value != null:
			return true
		return false
	func get_paused() -> bool:
		return __paused.value
	func clear_paused() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__paused.value = DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL]
	func set_paused(value : bool) -> void:
		__paused.value = value
	
	var __level: PBField
	func has_level() -> bool:
		if __level.value != null:
			return true
		return false
	func get_level() -> int:
		return __level.value
	func clear_level() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__level.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_level(value : int) -> void:
		__level.value = value
	
	var __experience: PBField
	func has_experience() -> bool:
		if __experience.value != null:
			return true
		return false
	func get_experience() -> int:
		return __experience.value
	func clear_experience() -> void:
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__experience.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_experience(value : int) -> void:
		__experience.value = value
	
	var __next_experience: PBField
	func has_next_experience() -> bool:
		if __next_experience.value != null:
			return true
		return false
	func get_next_experience() -> int:
		return __next_experience.value
	func clear_next_experience() -> void:
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__next_experience.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_next_experience(value : int) -> void:
		__next_experience.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class ExperienceOrb:
	extends RefCounted
	func _init():
		var service
		
		__orb_id = PBField.new("orb_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __orb_id
		data[__orb_id.tag] = service
		
		__x = PBField.new("x", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __x
		data[__x.tag] = service
		
		__y = PBField.new("y", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __y
		data[__y.tag] = service
		
		__value = PBField.new("value", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __value
		data[__value.tag] = service
		
	var data = {}
	
	var __orb_id: PBField
	func has_orb_id() -> bool:
		if __orb_id.value != null:
			return true
		return false
	func get_orb_id() -> String:
		return __orb_id.value
	func clear_orb_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__orb_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_orb_id(value : String) -> void:
		__orb_id.value = value
	
	var __x: PBField
	func has_x() -> bool:
		if __x.value != null:
			return true
		return false
	func get_x() -> float:
		return __x.value
	func clear_x() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__x.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_x(value : float) -> void:
		__x.value = value
	
	var __y: PBField
	func has_y() -> bool:
		if __y.value != null:
			return true
		return false
	func get_y() -> float:
		return __y.value
	func clear_y() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__y.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_y(value : float) -> void:
		__y.value = value
	
	var __value: PBField
	func has_value() -> bool:
		if __value.value != null:
			return true
		return false
	func get_value() -> int:
		return __value.value
	func clear_value() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__value.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_value(value : int) -> void:
		__value.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class LevelUpChoices:
	extends RefCounted
	func _init():
		var service
		
		__player_id = PBField.new("player_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __player_id
		data[__player_id.tag] = service
		
		var __reward_ids_default: Array[String] = []
		__reward_ids = PBField.new("reward_ids", PB_DATA_TYPE.STRING, PB_RULE.REPEATED, 2, true, __reward_ids_default)
		service = PBServiceField.new()
		service.field = __reward_ids
		data[__reward_ids.tag] = service
		
		var __labels_default: Array[String] = []
		__labels = PBField.new("labels", PB_DATA_TYPE.STRING, PB_RULE.REPEATED, 3, true, __labels_default)
		service = PBServiceField.new()
		service.field = __labels
		data[__labels.tag] = service
		
	var data = {}
	
	var __player_id: PBField
	func has_player_id() -> bool:
		if __player_id.value != null:
			return true
		return false
	func get_player_id() -> String:
		return __player_id.value
	func clear_player_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__player_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_player_id(value : String) -> void:
		__player_id.value = value
	
	var __reward_ids: PBField
	func get_reward_ids() -> Array[String]:
		return __reward_ids.value
	func clear_reward_ids() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__reward_ids.value.clear()
	func add_reward_ids(value : String) -> void:
		__reward_ids.value.append(value)
	
	var __labels: PBField
	func get_labels() -> Array[String]:
		return __labels.value
	func clear_labels() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__labels.value.clear()
	func add_labels(value : String) -> void:
		__labels.value.append(value)
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class ChooseReward:
	extends RefCounted
	func _init():
		var service
		
		__index = PBField.new("index", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __index
		data[__index.tag] = service
		
	var data = {}
	
	var __index: PBField
	func has_index() -> bool:
		if __index.value != null:
			return true
		return false
	func get_index() -> int:
		return __index.value
	func clear_index() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__index.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_index(value : int) -> void:
		__index.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class SurvivalResult:
	extends RefCounted
	func _init():
		var service
		
		__survival_seconds = PBField.new("survival_seconds", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __survival_seconds
		data[__survival_seconds.tag] = service
		
		__wave = PBField.new("wave", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __wave
		data[__wave.tag] = service
		
		__kills = PBField.new("kills", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __kills
		data[__kills.tag] = service
		
		__damage = PBField.new("damage", PB_DATA_TYPE.INT32, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT32])
		service = PBServiceField.new()
		service.field = __damage
		data[__damage.tag] = service
		
	var data = {}
	
	var __survival_seconds: PBField
	func has_survival_seconds() -> bool:
		if __survival_seconds.value != null:
			return true
		return false
	func get_survival_seconds() -> int:
		return __survival_seconds.value
	func clear_survival_seconds() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__survival_seconds.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_survival_seconds(value : int) -> void:
		__survival_seconds.value = value
	
	var __wave: PBField
	func has_wave() -> bool:
		if __wave.value != null:
			return true
		return false
	func get_wave() -> int:
		return __wave.value
	func clear_wave() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__wave.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_wave(value : int) -> void:
		__wave.value = value
	
	var __kills: PBField
	func has_kills() -> bool:
		if __kills.value != null:
			return true
		return false
	func get_kills() -> int:
		return __kills.value
	func clear_kills() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__kills.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_kills(value : int) -> void:
		__kills.value = value
	
	var __damage: PBField
	func has_damage() -> bool:
		if __damage.value != null:
			return true
		return false
	func get_damage() -> int:
		return __damage.value
	func clear_damage() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__damage.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT32]
	func set_damage(value : int) -> void:
		__damage.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class EntitySpawn:
	extends RefCounted
	func _init():
		var service
		
		__entity_info = PBField.new("entity_info", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __entity_info
		service.func_ref = Callable(self, "new_entity_info")
		data[__entity_info.tag] = service
		
		__combat = PBField.new("combat", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __combat
		service.func_ref = Callable(self, "new_combat")
		data[__combat.tag] = service
		
	var data = {}
	
	var __entity_info: PBField
	func has_entity_info() -> bool:
		if __entity_info.value != null:
			return true
		return false
	func get_entity_info() -> EntityInfo:
		return __entity_info.value
	func clear_entity_info() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_entity_info() -> EntityInfo:
		__entity_info.value = EntityInfo.new()
		return __entity_info.value
	
	var __combat: PBField
	func has_combat() -> bool:
		if __combat.value != null:
			return true
		return false
	func get_combat() -> CombatStatsEntry:
		return __combat.value
	func clear_combat() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__combat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_combat() -> CombatStatsEntry:
		__combat.value = CombatStatsEntry.new()
		return __combat.value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class MovementBatchEntry:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__x = PBField.new("x", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __x
		data[__x.tag] = service
		
		__y = PBField.new("y", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __y
		data[__y.tag] = service
		
		__moving = PBField.new("moving", PB_DATA_TYPE.BOOL, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL])
		service = PBServiceField.new()
		service.field = __moving
		data[__moving.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __x: PBField
	func has_x() -> bool:
		if __x.value != null:
			return true
		return false
	func get_x() -> float:
		return __x.value
	func clear_x() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__x.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_x(value : float) -> void:
		__x.value = value
	
	var __y: PBField
	func has_y() -> bool:
		if __y.value != null:
			return true
		return false
	func get_y() -> float:
		return __y.value
	func clear_y() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__y.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_y(value : float) -> void:
		__y.value = value
	
	var __moving: PBField
	func has_moving() -> bool:
		if __moving.value != null:
			return true
		return false
	func get_moving() -> bool:
		return __moving.value
	func clear_moving() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__moving.value = DEFAULT_VALUES_3[PB_DATA_TYPE.BOOL]
	func set_moving(value : bool) -> void:
		__moving.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class MovementBatch:
	extends RefCounted
	func _init():
		var service
		
		__tick = PBField.new("tick", PB_DATA_TYPE.INT64, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.INT64])
		service = PBServiceField.new()
		service.field = __tick
		data[__tick.tag] = service
		
		var __entries_default: Array[MovementBatchEntry] = []
		__entries = PBField.new("entries", PB_DATA_TYPE.MESSAGE, PB_RULE.REPEATED, 2, true, __entries_default)
		service = PBServiceField.new()
		service.field = __entries
		service.func_ref = Callable(self, "add_entries")
		data[__entries.tag] = service
		
	var data = {}
	
	var __tick: PBField
	func has_tick() -> bool:
		if __tick.value != null:
			return true
		return false
	func get_tick() -> int:
		return __tick.value
	func clear_tick() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__tick.value = DEFAULT_VALUES_3[PB_DATA_TYPE.INT64]
	func set_tick(value : int) -> void:
		__tick.value = value
	
	var __entries: PBField
	func get_entries() -> Array[MovementBatchEntry]:
		return __entries.value
	func clear_entries() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__entries.value.clear()
	func add_entries() -> MovementBatchEntry:
		var element = MovementBatchEntry.new()
		__entries.value.append(element)
		return element
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class EntityRelocated:
	extends RefCounted
	func _init():
		var service
		
		__entity_id = PBField.new("entity_id", PB_DATA_TYPE.STRING, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.STRING])
		service = PBServiceField.new()
		service.field = __entity_id
		data[__entity_id.tag] = service
		
		__x = PBField.new("x", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __x
		data[__x.tag] = service
		
		__y = PBField.new("y", PB_DATA_TYPE.FLOAT, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT])
		service = PBServiceField.new()
		service.field = __y
		data[__y.tag] = service
		
	var data = {}
	
	var __entity_id: PBField
	func has_entity_id() -> bool:
		if __entity_id.value != null:
			return true
		return false
	func get_entity_id() -> String:
		return __entity_id.value
	func clear_entity_id() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__entity_id.value = DEFAULT_VALUES_3[PB_DATA_TYPE.STRING]
	func set_entity_id(value : String) -> void:
		__entity_id.value = value
	
	var __x: PBField
	func has_x() -> bool:
		if __x.value != null:
			return true
		return false
	func get_x() -> float:
		return __x.value
	func clear_x() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__x.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_x(value : float) -> void:
		__x.value = value
	
	var __y: PBField
	func has_y() -> bool:
		if __y.value != null:
			return true
		return false
	func get_y() -> float:
		return __y.value
	func clear_y() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__y.value = DEFAULT_VALUES_3[PB_DATA_TYPE.FLOAT]
	func set_y(value : float) -> void:
		__y.value = value
	
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
class GameMessage:
	extends RefCounted
	func _init():
		var service
		
		__login = PBField.new("login", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 21, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __login
		service.func_ref = Callable(self, "new_login")
		data[__login.tag] = service
		
		__enter_room = PBField.new("enter_room", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 1, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __enter_room
		service.func_ref = Callable(self, "new_enter_room")
		data[__enter_room.tag] = service
		
		__leave_room = PBField.new("leave_room", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 2, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __leave_room
		service.func_ref = Callable(self, "new_leave_room")
		data[__leave_room.tag] = service
		
		__player_move = PBField.new("player_move", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 3, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __player_move
		service.func_ref = Callable(self, "new_player_move")
		data[__player_move.tag] = service
		
		__chat_message = PBField.new("chat_message", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 4, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __chat_message
		service.func_ref = Callable(self, "new_chat_message")
		data[__chat_message.tag] = service
		
		__game_state = PBField.new("game_state", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 5, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __game_state
		service.func_ref = Callable(self, "new_game_state")
		data[__game_state.tag] = service
		
		__heartbeat = PBField.new("heartbeat", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 6, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __heartbeat
		service.func_ref = Callable(self, "new_heartbeat")
		data[__heartbeat.tag] = service
		
		__player_facing = PBField.new("player_facing", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 7, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __player_facing
		service.func_ref = Callable(self, "new_player_facing")
		data[__player_facing.tag] = service
		
		__attack_start = PBField.new("attack_start", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 8, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __attack_start
		service.func_ref = Callable(self, "new_attack_start")
		data[__attack_start.tag] = service
		
		__attack_hit = PBField.new("attack_hit", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 9, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __attack_hit
		service.func_ref = Callable(self, "new_attack_hit")
		data[__attack_hit.tag] = service
		
		__attack_end = PBField.new("attack_end", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 10, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __attack_end
		service.func_ref = Callable(self, "new_attack_end")
		data[__attack_end.tag] = service
		
		__hurt_end = PBField.new("hurt_end", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 11, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __hurt_end
		service.func_ref = Callable(self, "new_hurt_end")
		data[__hurt_end.tag] = service
		
		__stats_init = PBField.new("stats_init", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 12, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __stats_init
		service.func_ref = Callable(self, "new_stats_init")
		data[__stats_init.tag] = service
		
		__stats_changed = PBField.new("stats_changed", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 13, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __stats_changed
		service.func_ref = Callable(self, "new_stats_changed")
		data[__stats_changed.tag] = service
		
		__hp_changed = PBField.new("hp_changed", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 14, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __hp_changed
		service.func_ref = Callable(self, "new_hp_changed")
		data[__hp_changed.tag] = service
		
		__entity_dead = PBField.new("entity_dead", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 15, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __entity_dead
		service.func_ref = Callable(self, "new_entity_dead")
		data[__entity_dead.tag] = service
		
		__entity_remove = PBField.new("entity_remove", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 16, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __entity_remove
		service.func_ref = Callable(self, "new_entity_remove")
		data[__entity_remove.tag] = service
		
		__ping = PBField.new("ping", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 17, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __ping
		service.func_ref = Callable(self, "new_ping")
		data[__ping.tag] = service
		
		__pong = PBField.new("pong", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 18, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __pong
		service.func_ref = Callable(self, "new_pong")
		data[__pong.tag] = service
		
		__map_info = PBField.new("map_info", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 19, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __map_info
		service.func_ref = Callable(self, "new_map_info")
		data[__map_info.tag] = service
		
		__ai_state_changed = PBField.new("ai_state_changed", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 20, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __ai_state_changed
		service.func_ref = Callable(self, "new_ai_state_changed")
		data[__ai_state_changed.tag] = service
		
		__survival_state = PBField.new("survival_state", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 23, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __survival_state
		service.func_ref = Callable(self, "new_survival_state")
		data[__survival_state.tag] = service
		
		__experience_orb = PBField.new("experience_orb", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 24, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __experience_orb
		service.func_ref = Callable(self, "new_experience_orb")
		data[__experience_orb.tag] = service
		
		__level_up_choices = PBField.new("level_up_choices", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 25, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __level_up_choices
		service.func_ref = Callable(self, "new_level_up_choices")
		data[__level_up_choices.tag] = service
		
		__choose_reward = PBField.new("choose_reward", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 26, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __choose_reward
		service.func_ref = Callable(self, "new_choose_reward")
		data[__choose_reward.tag] = service
		
		__survival_result = PBField.new("survival_result", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 27, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __survival_result
		service.func_ref = Callable(self, "new_survival_result")
		data[__survival_result.tag] = service
		
		__entity_spawn = PBField.new("entity_spawn", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 28, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __entity_spawn
		service.func_ref = Callable(self, "new_entity_spawn")
		data[__entity_spawn.tag] = service
		
		__movement_batch = PBField.new("movement_batch", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 29, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __movement_batch
		service.func_ref = Callable(self, "new_movement_batch")
		data[__movement_batch.tag] = service
		
		__entity_relocated = PBField.new("entity_relocated", PB_DATA_TYPE.MESSAGE, PB_RULE.OPTIONAL, 30, true, DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE])
		service = PBServiceField.new()
		service.field = __entity_relocated
		service.func_ref = Callable(self, "new_entity_relocated")
		data[__entity_relocated.tag] = service
		
	var data = {}
	
	enum MessageTypeCase {
		MESSAGE_TYPE_NOT_SET = 0,
		LOGIN = 21,
		ENTER_ROOM = 1,
		LEAVE_ROOM = 2,
		PLAYER_MOVE = 3,
		CHAT_MESSAGE = 4,
		GAME_STATE = 5,
		HEARTBEAT = 6,
		PLAYER_FACING = 7,
		ATTACK_START = 8,
		ATTACK_HIT = 9,
		ATTACK_END = 10,
		HURT_END = 11,
		STATS_INIT = 12,
		STATS_CHANGED = 13,
		HP_CHANGED = 14,
		ENTITY_DEAD = 15,
		ENTITY_REMOVE = 16,
		PING = 17,
		PONG = 18,
		MAP_INFO = 19,
		AI_STATE_CHANGED = 20,
		SURVIVAL_STATE = 23,
		EXPERIENCE_ORB = 24,
		LEVEL_UP_CHOICES = 25,
		CHOOSE_REWARD = 26,
		SURVIVAL_RESULT = 27,
		ENTITY_SPAWN = 28,
		MOVEMENT_BATCH = 29,
		ENTITY_RELOCATED = 30,
	}
	var _message_type_case: int = 0

	var __login: PBField
	func has_login() -> bool:
		return data[21].state == PB_SERVICE_STATE.FILLED
	func get_login() -> Login:
		return __login.value
	func clear_login() -> void:
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_login() -> Login:
		data[21].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 21
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__login.value = Login.new()
		return __login.value
	
	var __enter_room: PBField
	func has_enter_room() -> bool:
		return data[1].state == PB_SERVICE_STATE.FILLED
	func get_enter_room() -> EnterRoom:
		return __enter_room.value
	func clear_enter_room() -> void:
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_enter_room() -> EnterRoom:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		data[1].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 1
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = EnterRoom.new()
		return __enter_room.value
	
	var __leave_room: PBField
	func has_leave_room() -> bool:
		return data[2].state == PB_SERVICE_STATE.FILLED
	func get_leave_room() -> LeaveRoom:
		return __leave_room.value
	func clear_leave_room() -> void:
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_leave_room() -> LeaveRoom:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		data[2].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 2
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = LeaveRoom.new()
		return __leave_room.value
	
	var __player_move: PBField
	func has_player_move() -> bool:
		return data[3].state == PB_SERVICE_STATE.FILLED
	func get_player_move() -> PlayerMove:
		return __player_move.value
	func clear_player_move() -> void:
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_player_move() -> PlayerMove:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		data[3].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 3
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = PlayerMove.new()
		return __player_move.value
	
	var __chat_message: PBField
	func has_chat_message() -> bool:
		return data[4].state == PB_SERVICE_STATE.FILLED
	func get_chat_message() -> ChatMessage:
		return __chat_message.value
	func clear_chat_message() -> void:
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_chat_message() -> ChatMessage:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		data[4].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 4
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = ChatMessage.new()
		return __chat_message.value
	
	var __game_state: PBField
	func has_game_state() -> bool:
		return data[5].state == PB_SERVICE_STATE.FILLED
	func get_game_state() -> GameState:
		return __game_state.value
	func clear_game_state() -> void:
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_game_state() -> GameState:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		data[5].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 5
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = GameState.new()
		return __game_state.value
	
	var __heartbeat: PBField
	func has_heartbeat() -> bool:
		return data[6].state == PB_SERVICE_STATE.FILLED
	func get_heartbeat() -> Heartbeat:
		return __heartbeat.value
	func clear_heartbeat() -> void:
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_heartbeat() -> Heartbeat:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		data[6].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 6
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = Heartbeat.new()
		return __heartbeat.value
	
	var __player_facing: PBField
	func has_player_facing() -> bool:
		return data[7].state == PB_SERVICE_STATE.FILLED
	func get_player_facing() -> PlayerFacing:
		return __player_facing.value
	func clear_player_facing() -> void:
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_player_facing() -> PlayerFacing:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		data[7].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 7
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = PlayerFacing.new()
		return __player_facing.value
	
	var __attack_start: PBField
	func has_attack_start() -> bool:
		return data[8].state == PB_SERVICE_STATE.FILLED
	func get_attack_start() -> AttackStart:
		return __attack_start.value
	func clear_attack_start() -> void:
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_attack_start() -> AttackStart:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		data[8].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 8
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = AttackStart.new()
		return __attack_start.value
	
	var __attack_hit: PBField
	func has_attack_hit() -> bool:
		return data[9].state == PB_SERVICE_STATE.FILLED
	func get_attack_hit() -> AttackHit:
		return __attack_hit.value
	func clear_attack_hit() -> void:
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_attack_hit() -> AttackHit:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		data[9].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 9
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = AttackHit.new()
		return __attack_hit.value
	
	var __attack_end: PBField
	func has_attack_end() -> bool:
		return data[10].state == PB_SERVICE_STATE.FILLED
	func get_attack_end() -> AttackEnd:
		return __attack_end.value
	func clear_attack_end() -> void:
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_attack_end() -> AttackEnd:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		data[10].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 10
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = AttackEnd.new()
		return __attack_end.value
	
	var __hurt_end: PBField
	func has_hurt_end() -> bool:
		return data[11].state == PB_SERVICE_STATE.FILLED
	func get_hurt_end() -> HurtEnd:
		return __hurt_end.value
	func clear_hurt_end() -> void:
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_hurt_end() -> HurtEnd:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		data[11].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 11
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = HurtEnd.new()
		return __hurt_end.value
	
	var __stats_init: PBField
	func has_stats_init() -> bool:
		return data[12].state == PB_SERVICE_STATE.FILLED
	func get_stats_init() -> StatsInit:
		return __stats_init.value
	func clear_stats_init() -> void:
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_stats_init() -> StatsInit:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		data[12].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 12
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = StatsInit.new()
		return __stats_init.value
	
	var __stats_changed: PBField
	func has_stats_changed() -> bool:
		return data[13].state == PB_SERVICE_STATE.FILLED
	func get_stats_changed() -> StatsChanged:
		return __stats_changed.value
	func clear_stats_changed() -> void:
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_stats_changed() -> StatsChanged:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		data[13].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 13
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = StatsChanged.new()
		return __stats_changed.value
	
	var __hp_changed: PBField
	func has_hp_changed() -> bool:
		return data[14].state == PB_SERVICE_STATE.FILLED
	func get_hp_changed() -> HpChanged:
		return __hp_changed.value
	func clear_hp_changed() -> void:
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_hp_changed() -> HpChanged:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		data[14].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 14
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = HpChanged.new()
		return __hp_changed.value
	
	var __entity_dead: PBField
	func has_entity_dead() -> bool:
		return data[15].state == PB_SERVICE_STATE.FILLED
	func get_entity_dead() -> EntityDead:
		return __entity_dead.value
	func clear_entity_dead() -> void:
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_entity_dead() -> EntityDead:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		data[15].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 15
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = EntityDead.new()
		return __entity_dead.value
	
	var __entity_remove: PBField
	func has_entity_remove() -> bool:
		return data[16].state == PB_SERVICE_STATE.FILLED
	func get_entity_remove() -> EntityRemove:
		return __entity_remove.value
	func clear_entity_remove() -> void:
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_entity_remove() -> EntityRemove:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		data[16].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 16
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = EntityRemove.new()
		return __entity_remove.value
	
	var __ping: PBField
	func has_ping() -> bool:
		return data[17].state == PB_SERVICE_STATE.FILLED
	func get_ping() -> Ping:
		return __ping.value
	func clear_ping() -> void:
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_ping() -> Ping:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		data[17].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 17
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = Ping.new()
		return __ping.value
	
	var __pong: PBField
	func has_pong() -> bool:
		return data[18].state == PB_SERVICE_STATE.FILLED
	func get_pong() -> Pong:
		return __pong.value
	func clear_pong() -> void:
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_pong() -> Pong:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		data[18].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 18
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = Pong.new()
		return __pong.value
	
	var __map_info: PBField
	func has_map_info() -> bool:
		return data[19].state == PB_SERVICE_STATE.FILLED
	func get_map_info() -> MapInfo:
		return __map_info.value
	func clear_map_info() -> void:
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_map_info() -> MapInfo:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		data[19].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 19
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = MapInfo.new()
		return __map_info.value
	
	var __ai_state_changed: PBField
	func has_ai_state_changed() -> bool:
		return data[20].state == PB_SERVICE_STATE.FILLED
	func get_ai_state_changed() -> AiStateChanged:
		return __ai_state_changed.value
	func clear_ai_state_changed() -> void:
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_ai_state_changed() -> AiStateChanged:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		data[20].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 20
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = AiStateChanged.new()
		return __ai_state_changed.value
	
	var __survival_state: PBField
	func has_survival_state() -> bool:
		return data[23].state == PB_SERVICE_STATE.FILLED
	func get_survival_state() -> SurvivalState:
		return __survival_state.value
	func clear_survival_state() -> void:
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_survival_state() -> SurvivalState:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		data[23].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 23
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = SurvivalState.new()
		return __survival_state.value
	
	var __experience_orb: PBField
	func has_experience_orb() -> bool:
		return data[24].state == PB_SERVICE_STATE.FILLED
	func get_experience_orb() -> ExperienceOrb:
		return __experience_orb.value
	func clear_experience_orb() -> void:
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_experience_orb() -> ExperienceOrb:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		data[24].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 24
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = ExperienceOrb.new()
		return __experience_orb.value
	
	var __level_up_choices: PBField
	func has_level_up_choices() -> bool:
		return data[25].state == PB_SERVICE_STATE.FILLED
	func get_level_up_choices() -> LevelUpChoices:
		return __level_up_choices.value
	func clear_level_up_choices() -> void:
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_level_up_choices() -> LevelUpChoices:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		data[25].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 25
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = LevelUpChoices.new()
		return __level_up_choices.value
	
	var __choose_reward: PBField
	func has_choose_reward() -> bool:
		return data[26].state == PB_SERVICE_STATE.FILLED
	func get_choose_reward() -> ChooseReward:
		return __choose_reward.value
	func clear_choose_reward() -> void:
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_choose_reward() -> ChooseReward:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		data[26].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 26
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = ChooseReward.new()
		return __choose_reward.value
	
	var __survival_result: PBField
	func has_survival_result() -> bool:
		return data[27].state == PB_SERVICE_STATE.FILLED
	func get_survival_result() -> SurvivalResult:
		return __survival_result.value
	func clear_survival_result() -> void:
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_survival_result() -> SurvivalResult:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		data[27].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 27
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = SurvivalResult.new()
		return __survival_result.value
	
	var __entity_spawn: PBField
	func has_entity_spawn() -> bool:
		return data[28].state == PB_SERVICE_STATE.FILLED
	func get_entity_spawn() -> EntitySpawn:
		return __entity_spawn.value
	func clear_entity_spawn() -> void:
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_entity_spawn() -> EntitySpawn:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		data[28].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 28
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = EntitySpawn.new()
		return __entity_spawn.value
	
	var __movement_batch: PBField
	func has_movement_batch() -> bool:
		return data[29].state == PB_SERVICE_STATE.FILLED
	func get_movement_batch() -> MovementBatch:
		return __movement_batch.value
	func clear_movement_batch() -> void:
		data[29].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_movement_batch() -> MovementBatch:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		data[29].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 29
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = MovementBatch.new()
		return __movement_batch.value
	
	var __entity_relocated: PBField
	func has_entity_relocated() -> bool:
		return data[30].state == PB_SERVICE_STATE.FILLED
	func get_entity_relocated() -> EntityRelocated:
		return __entity_relocated.value
	func clear_entity_relocated() -> void:
		data[30].state = PB_SERVICE_STATE.UNFILLED
		__entity_relocated.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
	func new_entity_relocated() -> EntityRelocated:
		__login.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[21].state = PB_SERVICE_STATE.UNFILLED
		__enter_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[1].state = PB_SERVICE_STATE.UNFILLED
		__leave_room.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[2].state = PB_SERVICE_STATE.UNFILLED
		__player_move.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[3].state = PB_SERVICE_STATE.UNFILLED
		__chat_message.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[4].state = PB_SERVICE_STATE.UNFILLED
		__game_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[5].state = PB_SERVICE_STATE.UNFILLED
		__heartbeat.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[6].state = PB_SERVICE_STATE.UNFILLED
		__player_facing.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[7].state = PB_SERVICE_STATE.UNFILLED
		__attack_start.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[8].state = PB_SERVICE_STATE.UNFILLED
		__attack_hit.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[9].state = PB_SERVICE_STATE.UNFILLED
		__attack_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[10].state = PB_SERVICE_STATE.UNFILLED
		__hurt_end.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[11].state = PB_SERVICE_STATE.UNFILLED
		__stats_init.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[12].state = PB_SERVICE_STATE.UNFILLED
		__stats_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[13].state = PB_SERVICE_STATE.UNFILLED
		__hp_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[14].state = PB_SERVICE_STATE.UNFILLED
		__entity_dead.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[15].state = PB_SERVICE_STATE.UNFILLED
		__entity_remove.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[16].state = PB_SERVICE_STATE.UNFILLED
		__ping.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[17].state = PB_SERVICE_STATE.UNFILLED
		__pong.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[18].state = PB_SERVICE_STATE.UNFILLED
		__map_info.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[19].state = PB_SERVICE_STATE.UNFILLED
		__ai_state_changed.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[20].state = PB_SERVICE_STATE.UNFILLED
		__survival_state.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[23].state = PB_SERVICE_STATE.UNFILLED
		__experience_orb.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[24].state = PB_SERVICE_STATE.UNFILLED
		__level_up_choices.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[25].state = PB_SERVICE_STATE.UNFILLED
		__choose_reward.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[26].state = PB_SERVICE_STATE.UNFILLED
		__survival_result.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[27].state = PB_SERVICE_STATE.UNFILLED
		__entity_spawn.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[28].state = PB_SERVICE_STATE.UNFILLED
		__movement_batch.value = DEFAULT_VALUES_3[PB_DATA_TYPE.MESSAGE]
		data[29].state = PB_SERVICE_STATE.UNFILLED
		data[30].state = PB_SERVICE_STATE.FILLED
		_message_type_case = 30
		__entity_relocated.value = EntityRelocated.new()
		return __entity_relocated.value
	
	func get_message_type_case() -> int:
		return _message_type_case
	func _to_string() -> String:
		return PBPacker.message_to_string(data)
		
	func to_bytes() -> PackedByteArray:
		return PBPacker.pack_message(data)
		
	func from_bytes(bytes : PackedByteArray, offset : int = 0, limit : int = -1) -> int:
		var cur_limit = bytes.size()
		if limit != -1:
			cur_limit = limit
		var result = PBPacker.unpack_message(data, bytes, offset, cur_limit)
		if result == cur_limit:
			if PBPacker.check_required(data):
				if limit == -1:
					return PB_ERR.NO_ERRORS
			else:
				return PB_ERR.REQUIRED_FIELDS
		elif limit == -1 && result > 0:
			return PB_ERR.PARSE_INCOMPLETE
		return result
	
################ USER DATA END #################
