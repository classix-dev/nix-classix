# Ethereum Classic chain preset. Returns an attrset matching one entry
# in `safeMultisig.chains`. Takes `{ domain, rpcUri ? ... }` so the
# domain-dependent URLs (txs API, asset paths, default RPC pointing at
# a local CORS proxy on `rpc.<domain>`) resolve at consumer eval time.
#
# Consumers spread it into the chains option:
#
#   safeMultisig.chains.etc = nix-classix.lib.chains.etc { inherit domain; };
#   safeMultisig.primaryChain = "etc";
#
# Override individual fields via plain `//`:
#
#   safeMultisig.chains.etc =
#     (nix-classix.lib.chains.etc { inherit domain; })
#     // { rpcUri = "https://my-private-etc-node.example.com"; };
{
  domain,

  # Default points at the local CORS-injecting reverse proxy mounted
  # at `<domain>/rpc/` by the classix flavor (`rpc-cors-proxy` module).
  # Override if you're running your own ETC node or pointing at a
  # different public RPC that already sends CORS headers.
  rpcUri ? "https://${domain}/rpc/",
}:
{
  chainId = 61;
  shortName = "etc";
  chainName = "Ethereum Classic";
  description = "Ethereum Classic mainnet";
  isTestnet = false;
  l2 = false;
  inherit rpcUri;
  transactionService = "https://${domain}/txs";
  blockExplorerUriTemplate = {
    address = "https://blockscout.com/etc/mainnet/address/{{address}}";
    txHash = "https://blockscout.com/etc/mainnet/tx/{{txHash}}";
    api = "https://blockscout.com/etc/mainnet/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}";
  };
  nativeCurrency = {
    name = "Ether Classic";
    symbol = "ETC";
    decimals = 18;
    logoUri = "https://${domain}/assets/etc-logo.svg";
  };
  chainLogoUri = "https://${domain}/assets/etc-logo.svg";
}
