-- Copyright (C) 2012 Zhang "agentzh" Yichun (章亦春)

module("resty.dns.resolver", package.seeall)

_VERSION = '0.01'


local bit = require "bit"


local class = resty.dns.resolver
local udp = ngx.socket.udp
local rand = math.random
local char = string.char
local byte = string.byte
local strlen = string.len
local find = string.find
local gsub = string.gsub
local substr = string.sub
local format = string.format
local band = bit.band
local rshift = bit.rshift
local lshift = bit.lshift
local insert = table.insert
local concat = table.concat
local re_sub = ngx.re.sub


TYPE_A = 1
TYPE_CNAME = 5
TYPE_AAAA = 28


local resolver_errstrs = {
    "Format error",     -- 1
    "Server failure",   -- 2
    "Name Error",       -- 3
    "Not Implemented",  -- 4
    "Refused",          -- 5
}

local mt = { __index = class }


function new(self, opts)
    local sock, err = udp()
    if not sock then
        return nil, err
    end
    return setmetatable({ sock = sock }, mt)
end


function set_timeout(self, timeout)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:settimeout(timeout)
end


function connect(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:setpeername(...)
end


local function encode_name(s)
    return char(strlen(s)) .. s
end


local function decode_name(buf, pos)
    local labels = {}
    local nptrs = 0
    local p = pos
    while nptrs < 128 do
        local fst = byte(buf, p)

        if not fst then
            return nil, 'truncated';
        end

        -- ngx.say("fst at ", p, ": ", fst)

        if fst == 0 then
            break
        end

        if band(fst, 0xc0) ~= 0 then
            -- being a pointer
            if nptrs == 0 then
                pos = pos + 2
            end

            nptrs = nptrs + 1

            local snd = byte(buf, p + 1)
            if not snd then
                return nil, 'truncated'
            end

            p = lshift(band(fst, 0x3f), 8) + snd + 1

            -- ngx.say("resolving ptr ", p, ": ", byte(buf, p))

        else
            -- being a label
            local label = substr(buf, p + 1, p + fst)
            insert(labels, label)

            -- ngx.say("resolved label ", label)

            p = p + fst + 1

            if nptrs == 0 then
                pos = p
            end
        end
    end

    return concat(labels, "."), pos
end


function query(self, qname, qtype)
    local sock = self.sock
    if not sock then
        return nil, nil, "not initialized"
    end

    if not qtype then
        qtype = 1  -- A record
    end

    local id = rand(0, 65535)   -- two bytes
    local ident_hi = char(rshift(id, 8))
    local ident_lo = char(band(id, 0xff))

    local flags = "\1\0"    -- hard-coded RD flag
    local nqs = "\0\1"
    local nan = "\0\0"
    local nns = "\0\0"
    local nar = "\0\0"
    local typ = "\0" .. char(qtype)
    local class = "\0\1"    -- the Internet class

    local name = gsub(qname, "([^.]+)%.?", encode_name) .. '\0'

    local query = {
        ident_hi, ident_lo, flags, nqs, nan, nns, nar,
        name, typ, class
    }

    local ok, err = sock:send(query)
    if not ok then
        return nil, "failed to send DNS request: " .. err
    end

    local buf, err = sock:receive()
    if not buf then
        return nil, "failed to receive DNS response: " .. err
    end

    local n = strlen(buf)
    if n < 12 then
        return nil, 'truncated';
    end

    -- header layout: ident flags nqs nan nns nar

    local ident_hi = byte(buf, 1)
    local ident_lo = byte(buf, 2)
    local ans_id = lshift(ident_hi, 8) + ident_lo

    -- ngx.say("id: ", id, ", ans id: ", ans_id)

    if ans_id ~= id then
        return nil, format("identifier mismatch: %d ~= %d", ans_id, id)
    end

    local flags_hi = byte(buf, 3)
    local flags_lo = byte(buf, 4)
    local flags = lshift(flags_hi, 8) + flags_lo

    if band(flags, 0x8000) == 0 then
        return nil, format("invalid DNS response flag 0x%x", flags)
    end

    local code = band(flags, 0x7f)

    -- ngx.say(format("code: %d", code))

    if code ~= 0 then
        return nil, format("server returned %d: %s", code,
                           resolver_errstrs[code] or "unknown")
    end

    local nqs_hi = byte(buf, 5)
    local nqs_lo = byte(buf, 6)
    local nqs = lshift(nqs_hi, 8) + nqs_lo

    -- ngx.say("nqs: ", nqs)

    if nqs ~= 1 then
        return nil, format("bad number of questions in DNS response: %d", nqs)
    end

    local nan_hi = byte(buf, 7)
    local nan_lo = byte(buf, 8)
    local nan = lshift(nan_hi, 8) + nan_lo

    -- ngx.say("nan: ", nan)

    -- skip the question part

    local pos = find(buf, "\0", 13)
    if not pos then
        return nil, 'truncated';
    end

    -- ngx.say("byte at 13: ", byte(buf, 13))
    -- ngx.say("question: ", substr(buf, 13, pos))

    if pos + 4 + nan * (2 + 10) > n then
        return nil, 'truncated';
    end

    pos = pos + 1  -- skip '\0'

    -- question section layout: qname qtype(2) qclass(2)

    local type_hi = byte(buf, pos)
    local type_lo = byte(buf, pos + 1)
    local ans_type = lshift(type_hi, 8) + type_lo

    local class_hi = byte(buf, pos + 2)
    local class_lo = byte(buf, pos + 3)
    local qclass = lshift(class_hi, 8) + class_lo

    if qclass ~= 1 then
        return nil, format("unknown query class %d in DNS response", qclass)
    end

    pos = pos + 4

    local answers = {}

    for i = 1, nan do
        -- ngx.say(format("ans %d: qtype:%d qclass:%d", i, qtype, qclass))

        local ans = {}
        insert(answers, ans)

        local name
        name, pos = decode_name(buf, pos)
        if not name then
            return nil, pos
        end

        ans.name = name

        -- ngx.say("name: ", name)

        type_hi = byte(buf, pos)
        type_lo = byte(buf, pos + 1)
        local typ = lshift(type_hi, 8) + type_lo

        ans.typ = typ

        -- ngx.say("type: ", typ)

        class_hi = byte(buf, pos + 2)
        class_lo = byte(buf, pos + 3)
        local class = lshift(class_hi, 8) + class_lo

        ans.class = class

        -- ngx.say("class: ", class)

        local ttl_bytes = { byte(buf, pos + 4, pos + 7) }

        -- ngx.say("ttl bytes: ", concat(ttl_bytes, " "))

        local ttl = lshift(ttl_bytes[1], 24) + lshift(ttl_bytes[2], 16)
                    + lshift(ttl_bytes[3], 8) + ttl_bytes[4]

        -- ngx.say("ttl: ", ttl)

        ans.ttl = ttl

        local len_hi = byte(buf, pos + 8)
        local len_lo = byte(buf, pos + 9)
        local len = lshift(len_hi, 8) + len_lo

        -- ngx.say("len: ", len)

        pos = pos + 10

        if typ == TYPE_A then

            if len ~= 4 then
                return nil, "bad A record value length: " .. len
            end

            local addr_bytes = { byte(buf, pos, pos + 3) }
            local addr = concat(addr_bytes, ".")
            -- ngx.say("ipv4 address: ", addr)

            ans.address = addr

            pos = pos + 4

        elseif typ == TYPE_CNAME then

            local cname
            cname, pos = decode_name(buf, pos)
            if not cname then
                return nil, pos
            end

            -- ngx.say("cname: ", cname)

            ans.cname = cname

        elseif typ == TYPE_AAAA then

            if len ~= 16 then
                return nil, "bad AAAA record value length: " .. len
            end

            local addr_bytes = { byte(buf, pos, pos + 15) }
            local flds = {}
            local comp_begin, comp_end
            for i = 1, 16, 2 do
                local a = addr_bytes[i]
                local b = addr_bytes[i + 1]
                if a == 0 then
                    insert(flds, format("%x", b))

                else
                    insert(flds, format("%x%02x", a, b))
                end
            end

            local addr = concat(flds, ":")

            -- addr = '1080:0:0:0:8:800:200C:417A'
            -- addr = 'FF01:0:0:0:0:0:0:101'
            -- addr = '0:0:0:0:0:0:0:1'
            -- addr = '0:0:0:0:0:0:0:0'
            ans.address = re_sub(addr, "^(0:)+|:(0:)+|(:0)+$", "::", "jo")

            pos = pos + 16

        else
            pos = pos + len
        end
    end

    return answers
end


function close(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:close()
end


math.randomseed(ngx.time())


-- to prevent use of casual module global variables
getmetatable(class).__newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": '
            .. debug.traceback())
end
