import React from 'react';

export default function AgentAvatar({active = false, large = false}) {
  return <span className={`agent-avatar${active ? ' is-active' : ''}${large ? ' is-large' : ''}`} aria-hidden="true">
    <img src="./black-team-mark.png" alt="" width="512" height="512"/>
  </span>;
}
