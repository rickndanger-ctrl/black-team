import React from 'react';

// Display the supplied artwork unchanged, with its outer black margin clipped.
export default function Brand({caption = 'PRIVATE AI. TOTAL CONTROL.'}) {
  return <div className="brand black-team-brand">
    <div className="brand-lockup">
      <img src="./black-team-logo.png" alt="Black Team" width="2048" height="768"/>
    </div>
    <span className="brand-caption">{caption}</span>
  </div>;
}
