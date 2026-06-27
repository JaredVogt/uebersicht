export default (containerEl: HTMLElement) => {
  let insideWidget = false;

  const checkHover = (e: Event) => {
    if (insideWidget && containerEl === e.target) {
      insideWidget = false;
      (window as any).webkit.messageHandlers.dynamicd.postMessage('widgetLeave');
    } else if (!insideWidget && containerEl !== e.target) {
      insideWidget = true;
      (window as any).webkit.messageHandlers.dynamicd.postMessage('widgetEnter');
    }
  };

  const checkHoverRecursive = () => {
    window.addEventListener(
      'mousemove',
      (e) => {
        checkHover(e);
        setTimeout(checkHoverRecursive, 32);
      },
      {once: true},
    );
  };

  checkHoverRecursive();
};
