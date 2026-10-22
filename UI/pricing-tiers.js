// Edit plans here. Price IDs are from the Paddle sandbox catalog; swap in live IDs for production.
/**
 * @typedef {Object} Tier
 * @property {'Trial' | 'Creator' | 'Studio'} name
 * @property {string} description
 * @property {string[]} features
 * @property {string} priceId
 * @property {string} [badge]
 * @property {string} [trialLabel]
 */

/** @type {Tier[]} */
window.PRISM_TIERS = [
  {
    name: 'Trial',
    description: 'A low-cost way to start making Shorts.',
    features: [], // TODO: real perks for this plan
    priceId: 'pri_01m5h8qse4hefjmw1j9j9tn708',
  },
  {
    name: 'Creator',
    description: 'For creators publishing every week.',
    features: [], // TODO: real perks for this plan
    priceId: 'pri_01m5h8qspmxxtzsnankzef16t2',
    badge: 'Most popular',
    trialLabel: '7-day free trial',
  },
  {
    name: 'Studio',
    description: 'For teams and channels at full speed.',
    features: [], // TODO: real perks for this plan
    priceId: 'pri_01m5h8qszm3h86qpkn06wyx1y3',
    trialLabel: '7-day free trial',
  },
];
