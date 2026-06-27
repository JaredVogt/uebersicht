// middleware to serve the current state
export default (store: any) => (req: any, res: any, next: () => void) => {
  if (req.url === '/state/') {
    res.end(JSON.stringify(store.getState()));
  } else {
    next();
  }
};
