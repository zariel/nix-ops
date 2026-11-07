{ lib }:
family: rule:
let
  addressFamily = if family == "ipv4" then "ip" else "ip6";
  fields = {
    l4proto = "meta l4proto";
    saddr = "${addressFamily} saddr";
    daddr = "${addressFamily} daddr";
    etherSaddr = "ether saddr";
    sport = "th sport";
    dport = "th dport";
    icmpv6Type = "icmpv6 type";
  };
  unknown = lib.subtractLists (
    builtins.attrNames fields
    ++ [
      "verdict"
      "comment"
    ]
  ) (builtins.attrNames rule);
  verdict = rule.verdict or "accept";
  protocols = lib.toList (rule.l4proto or null);
  token =
    value:
    assert lib.assertMsg (
      builtins.isString value && builtins.match "[a-zA-Z0-9_.:/-]+" value != null
    ) "Gateway firewall match values must be single nftables tokens.";
    value;
  port =
    value:
    if builtins.isInt value then
      assert lib.assertMsg (
        value >= 0 && value <= 65535
      ) "Gateway firewall ports must be between 0 and 65535.";
      toString value
    else
      assert lib.assertMsg (
        builtins.isAttrs value
        &&
          builtins.attrNames value == [
            "from"
            "to"
          ]
      ) "Gateway firewall port ranges must contain from and to.";
      assert lib.assertMsg (value.from <= value.to) "Gateway firewall port ranges must be ascending.";
      "${port value.from}-${port value.to}";
  value =
    field: item:
    if builtins.isList item then
      assert lib.assertMsg (item != [ ]) "Gateway firewall match lists must not be empty.";
      "{ ${lib.concatMapStringsSep ", " (value field) item} }"
    else if builtins.isAttrs item && item ? set then
      assert lib.assertMsg (
        builtins.attrNames item == [ "set" ]
        && builtins.isString item.set
        && builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" item.set != null
      ) "Gateway firewall set references must contain a set name.";
      "@${item.set}"
    else if
      builtins.elem field [
        "sport"
        "dport"
      ]
    then
      port item
    else if field == "l4proto" && builtins.isInt item then
      assert lib.assertMsg (
        item >= 0 && item <= 255
      ) "Gateway firewall protocol numbers must be between 0 and 255.";
      toString item
    else
      token item;
  match =
    field:
    let
      item = rule.${field};
      expression = fields.${field};
    in
    if builtins.isAttrs item && item ? mask then
      assert lib.assertMsg (
        builtins.elem field [
          "saddr"
          "daddr"
        ]
        &&
          builtins.attrNames item == [
            "mask"
            "value"
          ]
      ) "Gateway firewall masks require an address field, mask and value.";
      "${expression} & ${token item.mask} == ${token item.value}"
    else
      "${expression} ${value field item}";
in
assert lib.assertMsg (builtins.elem family [
  "ipv4"
  "ipv6"
]) "Unknown gateway firewall address family.";
assert lib.assertMsg (
  unknown == [ ]
) "Unknown gateway firewall rule attributes: ${lib.concatStringsSep ", " unknown}";
assert lib.assertMsg (builtins.elem verdict [
  "accept"
  "drop"
]) "Gateway firewall rules must accept or drop.";
assert lib.assertMsg (
  !(rule ? comment) || builtins.isString rule.comment
) "Gateway firewall rule comments must be strings.";
assert lib.assertMsg (
  !(rule ? sport || rule ? dport)
  || lib.all (
    protocol:
    builtins.elem protocol [
      "tcp"
      "udp"
    ]
  ) protocols
) "Gateway firewall port matches require TCP or UDP protocols.";
assert lib.assertMsg (
  !(rule ? icmpv6Type) || (family == "ipv6" && protocols == [ "ipv6-icmp" ])
) "Gateway firewall ICMPv6 types require IPv6 and the ipv6-icmp protocol.";
lib.concatStringsSep " " (
  map match (
    lib.filter (field: builtins.hasAttr field rule) [
      "l4proto"
      "saddr"
      "daddr"
      "etherSaddr"
      "sport"
      "dport"
      "icmpv6Type"
    ]
  )
  ++ [
    "counter"
    verdict
  ]
  ++ lib.optional (rule ? comment) "comment ${builtins.toJSON rule.comment}"
)
