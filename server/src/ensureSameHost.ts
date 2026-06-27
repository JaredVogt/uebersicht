export default function ensureSameHost(host: string) {
    return ((req: any, res: any, next: () => void) => {
        if (req.headers.host && req.headers.host === host) {
            return next()
        }
        res.writeHead(400)
        res.end()
    })
}
