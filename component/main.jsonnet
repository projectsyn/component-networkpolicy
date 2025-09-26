local com = import 'lib/commodore.libjsonnet';
local espejo = import 'lib/espejo.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.networkpolicy;

local allowLabels =
  local deprecatedLabels = if std.length(params.allowNamespaceLabels) == 0 then
    []
  else
    std.trace(
      "Using deprecated parameter 'allowNamespaceLabels'. Please use 'basePolicy.allowNamespaceLabels' instead.",
      params.allowNamespaceLabels
    );
  local baseLabels = params.basePolicy.allowNamespaceLabels;
  params.allowNamespaceLabels + std.flattenArrays([
    if std.isArray(baseLabels[k]) then
      baseLabels[k]
    else if std.isObject(baseLabels[k]) then
      [ baseLabels[k] ]
    else if baseLabels[k] == null then
      []
    else
      error 'basePolicy.allowNamespaceLabels values must be arrays, objects, or null'
    for k in std.objectFields(baseLabels)
  ]);

local ignoredNamespaces = com.renderArray(params.ignoredNamespaces);

local plugin = std.asciiLower(params.networkPlugin);

local commonAnnotations = {
  'syn.tools/source': 'https://github.com/projectsyn/component-networkpolicy.git',
};

local commonItemLabels = {
  'app.kubernetes.io/managed-by': 'espejo',
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
  'internal.network-policies.syn.tools/migration-mark-for-purge': 'true',
};

local commonSyncLabels = {
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
};

local allowOthers = kube.NetworkPolicy('allow-from-other-namespaces') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonItemLabels,
  },
  spec+: {
    ingress+: [ {
      from: [
        {
          namespaceSelector: {
            matchLabels: {
              [key]: labels[key]
              for key in std.objectFields(labels)
            },
          },
        }
        for labels in allowLabels
      ],
    } ],
    // Hide unused optional egress field
    egress:: [],
  },
};

local ciliumClusterID =
  if params.basePolicy.cniPlugins.cilium.clusterID != '' then
    params.basePolicy.cniPlugins.cilium.clusterID
  else if params.ciliumClusterID != '' then
    std.trace("Using deprecated parameter 'ciliumClusterID'. Please use 'basePolicy.cniPlugins.cilium.clusterID' instead.", params.ciliumClusterID)
  else
    '';

local podSelector =
  if
    plugin == 'cilium' && ciliumClusterID != ''
  then
    {
      matchLabels: {
        'io.cilium.k8s.policy.cluster': ciliumClusterID,
      },
    }
  else
    {};

local allowSameNamespace = kube.NetworkPolicy('allow-from-same-namespace') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonItemLabels,
  },
  spec+: {
    ingress: [ {
      from: [ {
        podSelector: podSelector,
      } ],
    } ],
    // Hide unused optional egress field
    egress:: [],
  },
};

local allowFromNodeLabels =
  local legacyLabels = if std.length(params.allowFromNodeLabels) > 0 then
    std.trace("Using deprecated parameter 'allowFromNodeLabels'. Please use 'basePolicy.cniPlugins.cilium.allowFromNodeLabels' instead.", params.allowFromNodeLabels)
  else
    {};
  legacyLabels + params.basePolicy.cniPlugins.cilium.allowFromNodeLabels;

local ciliumNetworkPlugins =
  local ingressPolicies = if std.length(allowFromNodeLabels) > 0 then [
    {
      // always allow access from local node's host network, e.g. health checks.
      fromEntities: [ 'host' ],
    },
    {
      fromNodes: [
        {
          matchLabels: allowFromNodeLabels,
        },
      ],
    },
  ] else [
    {
      fromEntities: [
        'host',
        'remote-node',
      ],
    },
  ];
  [
    {
      apiVersion: 'cilium.io/v2',
      kind: 'CiliumNetworkPolicy',
      metadata: {
        name: 'allow-from-cluster-nodes',
        annotations+: commonAnnotations,
        labels+: commonItemLabels,
      },
      spec: {
        endpointSelector: {},
        ingress: ingressPolicies,
      },
    },
  ];

local baseSyncItems = (if plugin == 'cilium' then ciliumNetworkPlugins else []) +
                      (if std.length(allowLabels) > 0 then [ allowOthers ] else []);

local defaultSyncItems = [ allowSameNamespace ];

local defaultSyncConfig = espejo.syncConfig('networkpolicies-default') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonSyncLabels,
  },
  spec: {
    namespaceSelector: {
      ignoreNames: ignoredNamespaces,
      labelSelector: {
        matchExpressions: [
          {
            key: params.labels.noDefaults,
            operator: 'DoesNotExist',
          },
          {
            key: params.labels.baseDefaults,
            operator: 'DoesNotExist',
          },
        ],
      },
    },
    syncItems: defaultSyncItems + baseSyncItems,
  },
};

local baseSyncConfig = espejo.syncConfig('networkpolicies-base') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonSyncLabels,
  },
  spec: {
    namespaceSelector: {
      ignoreNames: ignoredNamespaces,
      labelSelector: {
        matchExpressions: [
          {
            key: params.labels.baseDefaults,
            operator: 'Exists',
          },
        ],
      },
    },
    syncItems: baseSyncItems,
  },
};

local purgeConfig(name, namespaceSelector, items) = espejo.syncConfig(name) {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonSyncLabels,
  },
  spec: {
    namespaceSelector: namespaceSelector,
    deleteItems: [ {
      apiVersion: policy.apiVersion,
      kind: policy.kind,
      name: policy.metadata.name,
    } for policy in items ],
  },
};

{
  '05_purge_defaults': [
    purgeConfig('networkpolicies-purge-defaults-ignored-namespaces', {
      matchNames: ignoredNamespaces,
    }, defaultSyncItems + baseSyncItems),
    purgeConfig('networkpolicies-purge-defaults-by-label', {
      labelSelector: {
        matchLabels: {
          [params.labels.purgeDefaults]: 'true',
        },
      },
    }, defaultSyncItems + baseSyncItems),
    purgeConfig('networkpolicies-purge-non-base-by-label', {
      labelSelector: {
        matchLabels: {
          [params.labels.purgeNonBase]: 'true',
        },
      },
    }, defaultSyncItems),
  ],
  '10_base_networkpolicies': baseSyncConfig,
  '10_default_networkpolicies': defaultSyncConfig,
}
